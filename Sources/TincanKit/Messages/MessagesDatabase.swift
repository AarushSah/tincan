import Foundation

/// A conversation with the facts needed to list it.
public struct ChatSummary: Sendable {
    public let chat: Chat
    public let lastMessage: Message?
    public let lastActivity: Date?
    public let unreadCount: Int
}

/// Read-only access to `~/Library/Messages/chat.db`.
///
/// Every query that returns message content first removes chats the person excluded, and
/// messages the person deleted, so neither is ever decoded, printed or handed to an agent.
public final class MessagesDatabase {
    public static var defaultPath: String {
        NSString(string: "~/Library/Messages/chat.db").expandingTildeInPath
    }

    public let database: SQLiteDatabase
    /// GUIDs of the messages tincan sent, from `SendLedger`, which mark them as tincan's.
    public var sentByTincan: Set<String> = []
    /// Chat ids that must never be read. Applied inside SQL, before bodies are decoded.
    public var excludedChatIDs: Set<Int64> {
        didSet { excludedHandleIDs = nil }
    }
    /// Handles of the people in excluded conversations and at excluded addresses, for
    /// messages Messages filed in no conversation at all. Found again when exclusions change.
    private var excludedHandleIDs: Set<Int64>?

    private let messageColumns: Set<String>
    private let chatColumns: Set<String>
    private let attachmentColumns: Set<String>
    /// Old databases store message dates in seconds; current ones in nanoseconds.
    private let datesInNanoseconds: Bool
    /// Whether the database has Recently Deleted (`chat_recoverable_message_join`). Older
    /// macOS releases don't.
    private let hasRecentlyDeleted: Bool

    /// A date as this database stores it, for query bounds.
    func dateValue(_ date: Date) -> Int64 {
        datesInNanoseconds ? AppleTime.messageValue(date) : AppleTime.saturating(date.timeIntervalSinceReferenceDate)
    }
    private var participantsCache: [Int64: [String]]?
    private var handleCache: [Int64: Handle]?
    private var soleParticipantCache: [Int64: String]?

    public init(path: String = MessagesDatabase.defaultPath, excludedChatIDs: Set<Int64> = []) throws {
        database = try SQLiteDatabase(path: path)
        self.excludedChatIDs = excludedChatIDs
        // Read the schema up front: a read that fails must fail, not pass for an older macOS
        // whose tables lack these columns.
        messageColumns = Set(try database.columns(of: "message"))
        chatColumns = Set(try database.columns(of: "chat"))
        attachmentColumns = Set(try database.columns(of: "attachment"))
        hasRecentlyDeleted = !(try database.columns(of: "chat_recoverable_message_join")).isEmpty
        datesInNanoseconds = try database.scalarInteger("SELECT MAX(date) FROM message").map { $0 > 100_000_000_000 } ?? true
    }

    /// Opens the database excluding the conversations in `references`: chat GUIDs (stable
    /// across database rebuilds and devices), `chat:<id>` row references, and excluded
    /// people's addresses (`address:+14155550142`), which exclude every one-to-one
    /// conversation with that address, including ones that start later. `region` reads
    /// numbers without a country code, as everywhere else.
    public convenience init(path: String = MessagesDatabase.defaultPath, excluding references: [String], region: String? = nil) throws {
        try self.init(path: path)
        exclusionEntries = references
        exclusionRegion = region
        try refreshExclusions()
    }

    /// The settings' exclusions and the region their addresses are read in, kept so new
    /// conversations on an excluded address are excluded as soon as they appear.
    private var exclusionEntries: [String] = []
    private var exclusionRegion: String?
    /// The chat and participant row counts exclusions were last resolved against.
    private var exclusionSignature: [Int64]?

    /// Finds excluded conversations again when conversations were added since the last
    /// time: a new one-to-one conversation on an excluded address, or one Messages made
    /// again under an excluded GUID after it was deleted, is excluded before any of its
    /// messages are read. Long-running readers such as `watch` call it before each read.
    public func refreshExclusions() throws {
        guard !exclusionEntries.isEmpty || exclusionSignature == nil else { return }
        let signature = try database.query(
            """
            SELECT (SELECT COUNT(*) FROM chat), (SELECT IFNULL(MAX(ROWID), 0) FROM chat), (SELECT COUNT(*) FROM chat_handle_join)
            """, [], { row in [row.int64(0) ?? 0, row.int64(1) ?? 0, row.int64(2) ?? 0] }
        ).first
        guard signature != exclusionSignature else { return }
        if exclusionSignature != nil {
            participantsCache = nil
            soleParticipantCache = nil
        }
        exclusionSignature = signature
        excludedChatIDs = try resolveExclusions(exclusionEntries, region: exclusionRegion)
        excludedHandleIDs = try resolveExcludedHandles()
    }

    /// The handles of everyone in an excluded conversation, groups included, and at an
    /// excluded address, whether or not a conversation with it exists yet.
    func resolveExcludedHandles() throws -> Set<Int64> {
        var ids = Set<Int64>()
        if !excludedChatIDs.isEmpty {
            let list = excludedChatIDs.sorted().map(String.init).joined(separator: ",")
            try database.forEach("SELECT handle_id FROM chat_handle_join WHERE chat_id IN (\(list))") { row in
                if let id = row.int64(0) { ids.insert(id) }
                return true
            }
        }
        let addresses = Set(exclusionEntries.compactMap { Exclusion.address(in: $0, region: exclusionRegion)?.value })
        if !addresses.isEmpty {
            try database.forEach("SELECT ROWID, id FROM handle") { row in
                if let id = row.int64(0), let address = row.string(1), addresses.contains(Address(address, region: exclusionRegion).value) {
                    ids.insert(id)
                }
                return true
            }
        }
        return ids
    }

    func resolveExclusions(_ references: [String], region: String?) throws -> Set<Int64> {
        var ids = try Self.resolveExclusions(references, in: database)
        let addresses = Set(references.compactMap { Exclusion.address(in: $0, region: region)?.value })
        guard !addresses.isEmpty else { return ids }
        // Every one-to-one conversation whose other person is at an excluded address.
        let participants = try participantsByChat()
        try database.forEach("SELECT ROWID, chat_identifier FROM chat WHERE style IS NULL OR style != 43") { row in
            guard let id = row.int64(0) else { return true }
            let others = participants[id] ?? [row.string(1) ?? ""]
            if others.allSatisfy({ addresses.contains(Address($0, region: region).value) }) { ids.insert(id) }
            return true
        }
        return ids
    }

    static func resolveExclusions(_ references: [String], in database: SQLiteDatabase) throws -> Set<Int64> {
        var ids = Set<Int64>()
        var guids: [String] = []
        for reference in references where Exclusion.address(in: reference, region: nil) == nil {
            // Hand-edited configs may say `Chat:42` or pad a GUID with spaces; neither may
            // silently stop an exclusion.
            switch ChatReference.parse(reference) {
            case .id(let id)?: ids.insert(id)
            case .guid(let guid)?: guids.append(guid)
            case nil: break
            }
        }
        if !guids.isEmpty {
            let placeholders = Array(repeating: "?", count: guids.count).joined(separator: ",")
            for id in try database.query("SELECT ROWID FROM chat WHERE guid IN (\(placeholders))", guids.map { .text($0) }, { $0.int64(0) ?? 0 }) {
                ids.insert(id)
            }
        }
        return ids
    }

    /// The SQL condition that removes messages tincan must never return. Every query that
    /// reads messages includes it, naming the message table `m`; `fetchMessages` adds it
    /// automatically. It removes:
    ///
    /// - messages filed in an excluded conversation, even when filed in another one too;
    /// - messages in Recently Deleted, whatever conversation they came from. Deleting moves
    ///   a message's link from `chat_message_join` to `chat_recoverable_message_join`, so a
    ///   query that only checked the first table would return it with no conversation,
    ///   past every exclusion. The person deleted it; tincan never shows it;
    /// - while anything is excluded, messages filed in no conversation at all whose person
    ///   is in an excluded conversation or at an excluded address, or who can't be told.
    ///   No conversation can exclude them, so their person does.
    var exclusionCondition: String? {
        var conditions: [String] = []
        if !excludedChatIDs.isEmpty {
            conditions.append(
                """
                NOT EXISTS (SELECT 1 FROM chat_message_join x WHERE x.message_id = m.ROWID \
                AND x.chat_id IN (\(excludedChatIDs.sorted().map(String.init).joined(separator: ","))))
                """)
        }
        if !excludedChatIDs.isEmpty || !exclusionEntries.isEmpty {
            if excludedHandleIDs == nil { excludedHandleIDs = try? resolveExcludedHandles() }
            // A failed lookup excludes every message with no conversation.
            let handles = excludedHandleIDs.map { $0.sorted().map(String.init).joined(separator: ",") }
            let attributable = handles.map { "IFNULL(m.handle_id, 0) != 0" + ($0.isEmpty ? "" : " AND m.handle_id NOT IN (\($0))") } ?? "0"
            conditions.append("(EXISTS (SELECT 1 FROM chat_message_join c WHERE c.message_id = m.ROWID) OR (\(attributable)))")
        }
        if let deleted = notDeleted("m.ROWID") { conditions.append(deleted) }
        return conditions.isEmpty ? nil : conditions.joined(separator: " AND ")
    }

    /// The SQL condition that message `m` is in none of `chatIDs`, for readers that leave
    /// conversations out, such as those Messages filed under Unknown Senders or Junk. Nil
    /// when there are none.
    private func outside(_ chatIDs: Set<Int64>) -> String? {
        guard !chatIDs.isEmpty else { return nil }
        return
            "NOT EXISTS (SELECT 1 FROM chat_message_join s WHERE s.message_id = m.ROWID AND s.chat_id IN (\(chatIDs.sorted().map(String.init).joined(separator: ","))))"
    }

    /// The SQL condition that the message with ROWID `messageID` is not in Recently Deleted.
    /// Nil when the database has no Recently Deleted.
    private func notDeleted(_ messageID: String) -> String? {
        guard hasRecentlyDeleted else { return nil }
        return "NOT EXISTS (SELECT 1 FROM chat_recoverable_message_join d WHERE d.message_id = \(messageID))"
    }

    /// Forgets cached handles and participants, for long-running readers such as `watch`
    /// that see new conversations appear.
    public func invalidateCaches() {
        participantsCache = nil
        handleCache = nil
        soleParticipantCache = nil
    }

    // MARK: Handles and chats

    /// All handle rows, keyed by `handle.ROWID`.
    public func handles() throws -> [Int64: Handle] {
        if let handleCache { return handleCache }
        var result: [Int64: Handle] = [:]
        for handle in try database.query(
            "SELECT ROWID, id, service FROM handle", [],
            { row in
                Handle(rowID: row.int64(0) ?? 0, address: row.string(1) ?? "", service: MessageService(databaseValue: row.string(2)))
            })
        {
            result[handle.rowID] = handle
        }
        handleCache = result
        return result
    }

    /// Participant addresses for every chat, excluding you.
    public func participantsByChat() throws -> [Int64: [String]] {
        if let participantsCache { return participantsCache }
        var result: [Int64: [String]] = [:]
        try database.forEach(
            """
            SELECT chj.chat_id, h.id FROM chat_handle_join chj
            JOIN handle h ON h.ROWID = chj.handle_id ORDER BY chj.chat_id, chj.handle_id
            """
        ) { row in
            if let chatID = row.int64(0), let address = row.string(1), result[chatID]?.contains(address) != true {
                result[chatID, default: []].append(address)
            }
            return true
        }
        participantsCache = result
        return result
    }

    /// The other person in each one-to-one chat, for rows Messages saved without a handle.
    /// Groups have none, even when only one other person is left in them.
    private func soleParticipants() throws -> [Int64: String] {
        if let soleParticipantCache { return soleParticipantCache }
        let participants = try participantsByChat()
        var result: [Int64: String] = [:]
        try database.forEach("SELECT ROWID FROM chat WHERE style IS NULL OR style != 43") { row in
            if let id = row.int64(0), let only = participants[id], only.count == 1 { result[id] = only[0] }
            return true
        }
        soleParticipantCache = result
        return result
    }

    /// Who wrote a row that is not yours: its handle, or the other person in a one-to-one
    /// chat. Nil when Messages did not record it; such rows are never attributed to you.
    private func author(handleID: Int64, chatID: Int64?) throws -> String? {
        if let address = try handles()[handleID]?.address { return address }
        guard let chatID else { return nil }
        return try soleParticipants()[chatID]
    }

    /// Reaction rows whose author is known: you, a recorded handle, or the other person in a
    /// one-to-one chat. Applied in SQL so a cursor's limit counts only rows it returns.
    private func knownReactorCondition() throws -> String {
        let direct = try soleParticipants().keys.sorted().map(String.init).joined(separator: ",")
        return "(m.is_from_me = 1 OR EXISTS (SELECT 1 FROM handle h WHERE h.ROWID = m.handle_id) OR cmj.chat_id IN (\(direct)))"
    }

    /// Every chat, excluded chats included (they are listed as excluded, never read).
    public func allChats() throws -> [Chat] {
        let participants = try participantsByChat()
        let properties = chatColumns.contains("properties") ? "properties" : "NULL"
        let archived = chatColumns.contains("is_archived") ? "is_archived" : "0"
        let filtered = chatColumns.contains("is_filtered") ? "is_filtered" : "0"
        return try database.query(
            """
            SELECT ROWID, guid, style, service_name, display_name, chat_identifier, \(archived), \(filtered), \(properties)
            FROM chat
            """
        ) { row in
            let id = row.int64(0) ?? 0
            return Chat(
                id: id,
                guid: row.string(1) ?? "",
                kind: row.int(2) == 43 ? .group : .direct,
                service: MessageService(databaseValue: row.string(3)),
                displayName: row.nonEmptyString(4),
                identifier: row.string(5) ?? "",
                participants: participants[id] ?? [],
                isArchived: row.bool(6),
                isFiltered: (row.int(7) ?? 0) != 0,
                sendsReadReceipts: Self.readReceiptSetting(row.data(8))
            )
        }
    }

    public func chat(id: Int64) throws -> Chat? {
        try allChats().first { $0.id == id }
    }

    public func chat(guid: String) throws -> Chat? {
        try allChats().first { $0.guid == guid }
    }

    /// Most recent message date per chat, from the join table's index. Deleted messages
    /// don't count, and excluded chats have none: their timing is theirs too.
    public func lastActivityByChat() throws -> [Int64: Date] {
        var result: [Int64: Date] = [:]
        let deleted = notDeleted("j.message_id").map { " WHERE \($0)" } ?? ""
        try database.forEach("SELECT j.chat_id, MAX(j.message_date) FROM chat_message_join j\(deleted) GROUP BY j.chat_id") { row in
            if let chatID = row.int64(0), !excludedChatIDs.contains(chatID), let date = AppleTime.messageDate(row.int64(1)) { result[chatID] = date }
            return true
        }
        return result
    }

    /// Number of messages in each chat. Reactions and group events are not messages, and
    /// excluded chats are left out.
    public func messageCounts(chatIDs: [Int64]) throws -> [Int64: Int] {
        let allowed = chatIDs.filter { !excludedChatIDs.contains($0) }
        guard !allowed.isEmpty else { return [:] }
        var conditions = ["cmj.chat_id IN (\(allowed.map(String.init).joined(separator: ",")))", Self.notReaction, "\(optional("item_type", "0")) = 0"]
        if let exclusion = exclusionCondition { conditions.append(exclusion) }
        var result: [Int64: Int] = [:]
        try database.forEach(
            """
            SELECT cmj.chat_id, COUNT(*) FROM chat_message_join cmj JOIN message m ON m.ROWID = cmj.message_id
            WHERE \(conditions.joined(separator: " AND ")) GROUP BY cmj.chat_id
            """
        ) { row in
            if let chatID = row.int64(0) { result[chatID] = row.int(1) ?? 0 }
            return true
        }
        return result
    }

    /// The service and direction of `chatID`'s newest messages after `since`, newest first,
    /// at most `limit`: which service the conversation actually uses, whatever its chat
    /// record says. Reactions, group events and messages Messages failed to send don't
    /// count, and an excluded conversation has none. Returns no message content.
    public func recentServices(inChat chatID: Int64, since: Date?, limit: Int) throws -> [ServiceUse] {
        guard !excludedChatIDs.contains(chatID), limit > 0 else { return [] }
        var conditions = [
            "cmj.chat_id = ?", Self.notReaction, "\(optional("item_type", "0")) = 0", "NOT (m.is_from_me = 1 AND \(optional("error", "0")) != 0)",
        ]
        var bindings: [SQLiteValue] = [.integer(chatID)]
        if let since {
            conditions.append("cmj.message_date > ?")
            bindings.append(.integer(dateValue(since)))
        }
        if let exclusion = exclusionCondition { conditions.append(exclusion) }
        return try database.query(
            """
            SELECT m.service, m.is_from_me, cmj.message_date FROM chat_message_join cmj JOIN message m ON m.ROWID = cmj.message_id
            WHERE \(conditions.joined(separator: " AND ")) ORDER BY cmj.message_date DESC, m.ROWID DESC LIMIT ?
            """, bindings + [.integer(Int64(limit))]
        ) { row in
            ServiceUse(
                service: MessageService(databaseValue: row.string(0)), isFromMe: (row.int64(1) ?? 0) != 0,
                date: AppleTime.messageDate(row.int64(2)) ?? .distantPast)
        }
    }

    /// Unread incoming messages per chat. Reactions and group events do not count, and
    /// excluded chats report nothing.
    public func unreadCountByChat() throws -> [Int64: Int] {
        var conditions = ["m.is_read = 0", "m.is_from_me = 0", "m.item_type = 0", "m.is_finished = 1", "m.associated_message_type = 0"]
        if let exclusion = exclusionCondition { conditions.append(exclusion) }
        var result: [Int64: Int] = [:]
        try database.forEach(
            """
            SELECT cmj.chat_id, COUNT(*) FROM message m
            JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
            WHERE \(conditions.joined(separator: " AND "))
            GROUP BY cmj.chat_id
            """
        ) { row in
            if let chatID = row.int64(0) { result[chatID] = row.int(1) ?? 0 }
            return true
        }
        return result
    }

    public enum ChatCursorError: Error {
        case notInResults
    }

    /// Conversations ordered by latest activity, then descending id to break ties.
    /// `beforeChat` continues after that conversation in the filtered list.
    public func chatSummaries(
        limit: Int?, unreadOnly: Bool = false, includeFiltered: Bool = false, chatIDs: Set<Int64>? = nil, beforeChat: Int64? = nil
    ) throws -> [ChatSummary] {
        let activity = try lastActivityByChat()
        let unread = try unreadCountByChat()
        var chats = try allChats().filter { chat in
            if let chatIDs, !chatIDs.contains(chat.id) { return false }
            if !includeFiltered, chat.isFiltered, chatIDs == nil { return false }
            if unreadOnly, (unread[chat.id] ?? 0) == 0 { return false }
            // Excluded chats are still listed, so they can be brought back, without their timing.
            return activity[chat.id] != nil || excludedChatIDs.contains(chat.id) || chatIDs != nil
        }
        chats.sort {
            let left = activity[$0.id] ?? .distantPast
            let right = activity[$1.id] ?? .distantPast
            return left == right ? $0.id > $1.id : left > right
        }
        if let beforeChat {
            guard let index = chats.firstIndex(where: { $0.id == beforeChat }) else { throw ChatCursorError.notInResults }
            chats = Array(chats.dropFirst(index + 1))
        }
        if let limit { chats = Array(chats.prefix(limit)) }
        return try chats.map { chat in
            let last = excludedChatIDs.contains(chat.id) ? nil : try messages(inChats: [chat.id], limit: 1).last
            return ChatSummary(chat: chat, lastMessage: last, lastActivity: activity[chat.id], unreadCount: unread[chat.id] ?? 0)
        }
    }

    // MARK: Messages

    /// Messages in `chatIDs`, oldest first, with reactions folded in. `before` and `after`
    /// are exclusive bounds on the message date; the newest `limit` messages are returned.
    ///
    /// `beforeMessage` and `afterMessage` bound the page by another message, ordering by
    /// (date, ROWID) so messages sharing a timestamp are never skipped. With `afterMessage`
    /// the oldest `limit` messages after it are returned instead, for reading forward.
    public func messages(
        inChats chatIDs: [Int64], before: Date? = nil, after: Date? = nil, beforeMessage: Int64? = nil, afterMessage: Int64? = nil, limit: Int = 50
    ) throws -> [Message] {
        let allowed = chatIDs.filter { !excludedChatIDs.contains($0) }
        guard !allowed.isEmpty, limit > 0 else { return [] }
        var conditions = ["cmj.chat_id IN (\(allowed.map(String.init).joined(separator: ",")))", Self.notReaction]
        var bindings: [SQLiteValue] = []
        if let beforeMessage {
            // An unknown or excluded anchor pages from nothing, so its date cannot leak.
            guard let anchor = try anchorDate(beforeMessage) else { return [] }
            conditions.append("(cmj.message_date < ? OR (cmj.message_date = ? AND m.ROWID < ?))")
            bindings.append(contentsOf: [.integer(anchor), .integer(anchor), .integer(beforeMessage)])
        }
        if let afterMessage {
            guard let anchor = try anchorDate(afterMessage) else { return [] }
            conditions.append("(cmj.message_date > ? OR (cmj.message_date = ? AND m.ROWID > ?))")
            bindings.append(contentsOf: [.integer(anchor), .integer(anchor), .integer(afterMessage)])
        }
        if let before {
            conditions.append("cmj.message_date < ?")
            bindings.append(.integer(self.dateValue(before)))
        }
        if let after {
            conditions.append("cmj.message_date > ?")
            bindings.append(.integer(self.dateValue(after)))
        }
        bindings.append(.integer(Int64(limit)))
        let forward = afterMessage != nil
        let rows = try fetchMessages(
            where: conditions.joined(separator: " AND "),
            order: forward ? "cmj.message_date ASC, m.ROWID ASC" : "cmj.message_date DESC, m.ROWID DESC",
            bindings: bindings
        )
        return try complete(forward ? rows : rows.reversed(), reactionChats: allowed)
    }

    /// The date a message is filed under, for paging from it. Nil when the message is unknown
    /// or excluded, or is a reaction, which is not a message of its own.
    private func anchorDate(_ id: Int64) throws -> Int64? {
        let conditions = ["m.ROWID = ?", Self.notReaction] + (exclusionCondition.map { [$0] } ?? [])
        return try database.scalarInteger(
            """
            SELECT MAX(cmj.message_date) FROM message m JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
            WHERE \(conditions.joined(separator: " AND "))
            """, [.integer(id)])
    }

    /// New messages across every chat after `rowID`, oldest first. This is the cursor that
    /// lets an assistant read "everything since last time" without missing or repeating rows.
    /// Messages in `skipping` are left out before `limit` counts them.
    public func messages(
        afterRowID rowID: Int64, through ceiling: Int64? = nil, limit: Int, includeFromMe: Bool = true, skipping: Set<Int64> = []
    ) throws -> [Message] {
        var conditions = ["m.ROWID > ?", Self.notReaction]
        if let ceiling { conditions.append("m.ROWID <= \(ceiling)") }
        if !includeFromMe { conditions.append("m.is_from_me = 0") }
        if let skipped = outside(skipping) { conditions.append(skipped) }
        let rows = try fetchMessages(
            where: conditions.joined(separator: " AND "),
            order: "m.ROWID ASC",
            bindings: [.integer(rowID), .integer(Int64(limit))],
            leftJoinChats: true
        )
        let chats = Array(Set(rows.compactMap(\.chatID)))
        return try complete(rows, reactionChats: chats)
    }

    /// Reactions that arrived after `rowID`, for assistants that watch a cursor. Reactions by
    /// someone Messages did not record are left out, never reported as yours, and so are
    /// reactions to a message the person deleted.
    public func reactionRows(
        afterRowID rowID: Int64, limit: Int
    ) throws -> [(targetGUID: String, reaction: Reaction, removed: Bool, chatID: Int64?, rowID: Int64)] {
        var conditions = ["m.ROWID > ?", Self.isReaction, try knownReactorCondition()]
        if let exclusion = exclusionCondition { conditions.append(exclusion) }
        if hasRecentlyDeleted {
            conditions.append(
                """
                NOT EXISTS (SELECT 1 FROM message t JOIN chat_recoverable_message_join d ON d.message_id = t.ROWID \
                WHERE t.guid = \(Self.reactionTarget))
                """)
        }
        let emoji = messageColumns.contains("associated_message_emoji") ? "m.associated_message_emoji" : "NULL"
        return try database.query(
            """
            SELECT m.ROWID, m.associated_message_guid, m.associated_message_type, \(emoji), m.is_from_me, m.handle_id, m.date, cmj.chat_id
            FROM message m LEFT JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
            WHERE \(conditions.joined(separator: " AND ")) ORDER BY m.ROWID ASC LIMIT ?
            """, [.integer(rowID), .integer(Int64(limit))]
        ) { row -> (targetGUID: String, reaction: Reaction, removed: Bool, chatID: Int64?, rowID: Int64)? in
            let from = row.bool(4) ? nil : try author(handleID: row.int64(5) ?? 0, chatID: row.int64(7))
            if !row.bool(4), from == nil { return nil }
            let (guid, part) = Self.parseAssociatedGUID(row.string(1) ?? "")
            let type = row.int(2) ?? 0
            let reaction = Reaction(
                // A removal (3000-3007) names the kind it takes back (2000-2007).
                kind: Self.reactionKind((3000...3007).contains(type) ? type - 1000 : type) ?? .like,
                emoji: row.nonEmptyString(3),
                from: from,
                at: AppleTime.messageDate(row.int64(6)) ?? Date(timeIntervalSinceReferenceDate: 0),
                part: part
            )
            return (guid, reaction, type >= 3000 && type < 4000, row.int64(7), row.int64(0) ?? 0)
        }.compactMap { $0 }
    }

    /// Unread messages from other people, oldest first, leaving out those in `skipping`.
    public func unreadMessages(limit: Int, skipping: Set<Int64> = []) throws -> [Message] {
        var conditions = ["m.is_read = 0", "m.is_from_me = 0", "m.item_type = 0", "m.is_finished = 1", "m.associated_message_type = 0"]
        if let skipped = outside(skipping) { conditions.append(skipped) }
        let rows = try fetchMessages(where: conditions.joined(separator: " AND "), order: "m.date DESC", bindings: [.integer(Int64(limit))])
        return try complete(rows.reversed(), reactionChats: Array(Set(rows.compactMap(\.chatID))))
    }

    /// A cursor that reads every message dated after `date`: just below the first such row,
    /// or the latest row when there is none. Rows are not written in date order (late
    /// deliveries, iCloud sync), so a cursor at the last row dated before `date` could skip
    /// newer ones.
    public func rowID(before date: Date) throws -> Int64 {
        guard let first = try database.scalarInteger("SELECT MIN(ROWID) FROM message WHERE date > ?", [.integer(self.dateValue(date))]) else {
            return try latestRowID()
        }
        return first - 1
    }

    /// Your own phone numbers and emails, most used first, from the addresses your sent
    /// messages went out from.
    public func ownAddresses() throws -> [String] {
        var counts: [String: Int] = [:]
        if messageColumns.contains("destination_caller_id") {
            try database.forEach(
                """
                SELECT destination_caller_id, COUNT(*) FROM message
                WHERE is_from_me = 1 AND destination_caller_id IS NOT NULL AND destination_caller_id != ''
                GROUP BY destination_caller_id
                """
            ) { row in
                if let value = row.string(0), value.hasPrefix("+") || value.contains("@") { counts[value, default: 0] += row.int(1) ?? 0 }
                return true
            }
        }
        try database.forEach("SELECT account, COUNT(*) FROM message WHERE is_from_me = 1 AND account IS NOT NULL GROUP BY account") { row in
            if let value = row.string(0), value.count > 2, value.hasPrefix("E:") || value.hasPrefix("P:") || value.hasPrefix("e:") || value.hasPrefix("p:") {
                counts[String(value.dropFirst(2)), default: 0] += row.int(1) ?? 0
            }
            return true
        }
        return counts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.map(\.key)
    }

    /// The highest message ROWID: the cursor for "from now on".
    public func latestRowID() throws -> Int64 {
        try database.scalarInteger("SELECT MAX(ROWID) FROM message") ?? 0
    }

    /// Messages by GUID, for resolving reply and reaction targets. Reactions are not messages
    /// of their own, so their GUIDs find nothing.
    public func messages(guids: [String]) throws -> [Message] {
        guard !guids.isEmpty else { return [] }
        let placeholders = Array(repeating: "?", count: guids.count).joined(separator: ",")
        let conditions = ["m.guid IN (\(placeholders))", Self.notReaction]
        let rows = try fetchMessages(
            where: conditions.joined(separator: " AND "),
            order: "m.ROWID ASC",
            bindings: guids.map { .text($0) } + [.integer(Int64(guids.count))],
            leftJoinChats: true
        )
        return try complete(rows, reactionChats: Array(Set(rows.compactMap(\.chatID))))
    }

    /// Row ids by GUID, so a reaction's target can be named as `m:<id>`. Messages in excluded
    /// conversations and in Recently Deleted are left out, like everywhere; nothing is decoded.
    public func rowIDs(guids: [String]) throws -> [String: Int64] {
        let unique = Array(Set(guids.filter { !$0.isEmpty }))
        guard !unique.isEmpty else { return [:] }
        var conditions = ["m.guid IN (\(Array(repeating: "?", count: unique.count).joined(separator: ",")))"]
        if let exclusion = exclusionCondition { conditions.append(exclusion) }
        var result: [String: Int64] = [:]
        try database.forEach("SELECT m.guid, m.ROWID FROM message m WHERE \(conditions.joined(separator: " AND "))", unique.map { .text($0) }) { row in
            if let guid = row.string(0), let id = row.int64(1) { result[guid] = id }
            return true
        }
        return result
    }

    /// Scans messages newest first and returns those whose decoded text contains `query`
    /// (ignoring case, accents and typographic punctuation; see `TextFolding`). Bodies must be decoded to search, so this reads
    /// rows until `limit` matches are found. `beforeMessage` continues from an earlier page's
    /// oldest match, by (date, ROWID) so matches sharing a timestamp are never skipped.
    /// Messages in `skipping` are never matched.
    public func search(
        _ query: String, inChats chatIDs: [Int64]? = nil, fromMeOnly: Bool? = nil, senders: Set<String>? = nil, after: Date? = nil, before: Date? = nil,
        beforeMessage: Int64? = nil, skipping: Set<Int64> = [], limit: Int
    ) throws -> [Message] {
        let needle = TextFolding.fold(query)
        guard !needle.isEmpty, limit > 0 else { return [] }
        var conditions = [Self.notReaction, "m.item_type = 0"]
        var bindings: [SQLiteValue] = []
        if let chatIDs {
            let allowed = chatIDs.filter { !excludedChatIDs.contains($0) }
            guard !allowed.isEmpty else { return [] }
            conditions.append("cmj.chat_id IN (\(allowed.map(String.init).joined(separator: ",")))")
        }
        if let exclusion = exclusionCondition { conditions.append(exclusion) }
        if let skipped = outside(skipping) { conditions.append(skipped) }
        if let fromMeOnly { conditions.append("m.is_from_me = \(fromMeOnly ? 1 : 0)") }
        if let beforeMessage {
            // An unknown or excluded anchor pages from nothing, so its date cannot leak.
            let anchorConditions = ["m.ROWID = ?", Self.notReaction] + (exclusionCondition.map { [$0] } ?? [])
            guard
                let anchor = try database.scalarInteger(
                    "SELECT m.date FROM message m WHERE \(anchorConditions.joined(separator: " AND "))", [.integer(beforeMessage)])
            else { return [] }
            conditions.append("(m.date < ? OR (m.date = ? AND m.ROWID < ?))")
            bindings.append(contentsOf: [.integer(anchor), .integer(anchor), .integer(beforeMessage)])
        }
        if let before {
            conditions.append("m.date < ?")
            bindings.append(.integer(self.dateValue(before)))
        }
        if let after {
            conditions.append("m.date > ?")
            bindings.append(.integer(self.dateValue(after)))
        }
        let handles = try handles()
        let fold = TextFolding.fold
        // Scan cheaply: read each body's text straight from its archive bytes, and decode
        // only rows that match. Decoding every attributed string makes a full scan ~10× slower.
        var candidates: [Int64] = []
        let sql = """
            SELECT m.ROWID, m.text, m.attributedBody, m.is_from_me, m.handle_id
            FROM message m JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
            WHERE \(conditions.joined(separator: " AND ")) ORDER BY m.date DESC, m.ROWID DESC
            """
        try database.forEach(sql, bindings) { row in
            guard fold(MessageBody.quickText(text: row.string(1), attributedBody: row.data(2))).contains(needle) else { return true }
            if let senders {
                let address = row.bool(3) ? nil : handles[row.int64(4) ?? 0]?.address
                guard let address, senders.contains(address) else { return true }
            }
            if let id = row.int64(0), !candidates.contains(id) { candidates.append(id) }
            return candidates.count < limit
        }
        guard !candidates.isEmpty else { return [] }
        let rows = try fetchMessages(
            where: "m.ROWID IN (\(candidates.map(String.init).joined(separator: ",")))",
            order: "m.date DESC, m.ROWID DESC",
            bindings: [.integer(Int64(candidates.count * 4))],
            leftJoinChats: true
        )
        var seen = Set<Int64>()
        // Confirm on the fully decoded text so results are exact.
        let matches = rows.filter { seen.insert($0.rowID).inserted && fold($0.body.text).contains(needle) }
        return try complete(matches, reactionChats: Array(Set(matches.compactMap(\.chatID))))
    }

    /// The newest message you sent in `chatID` after `date`, used to confirm a send landed.
    public func latestOutgoing(inChat chatID: Int64?, after date: Date) throws -> [Message] {
        var conditions = ["m.is_from_me = 1", "m.date > ?", Self.notReaction]
        if let chatID { conditions.append("cmj.chat_id = \(chatID)") }
        let rows = try fetchMessages(
            where: conditions.joined(separator: " AND "),
            order: "m.ROWID DESC",
            bindings: [.integer(self.dateValue(date)), .integer(20)],
            leftJoinChats: true
        )
        return try complete(rows.reversed(), reactionChats: Array(Set(rows.compactMap(\.chatID))))
    }

    /// When you first sent something in `chatID` after `date`, for "did I get back to them?".
    public func firstOutgoingDate(inChat chatID: Int64, after date: Date) throws -> Date? {
        guard !excludedChatIDs.contains(chatID) else { return nil }
        let exclusion = exclusionCondition.map { " AND \($0)" } ?? ""
        let value = try database.scalarInteger(
            """
            SELECT MIN(cmj.message_date) FROM chat_message_join cmj JOIN message m ON m.ROWID = cmj.message_id
            WHERE cmj.chat_id = ? AND cmj.message_date > ? AND m.is_from_me = 1 AND \(Self.notReaction)\(exclusion)
            """, [.integer(chatID), .integer(self.dateValue(date))])
        return AppleTime.messageDate(value)
    }

    /// Messages you sent after `rowID`, oldest first: how a send is confirmed without
    /// trusting clocks or matching an earlier identical message.
    public func outgoing(inChat chatID: Int64?, afterRowID rowID: Int64, limit: Int = 20) throws -> [Message] {
        var conditions = ["m.is_from_me = 1", "m.ROWID > ?", Self.notReaction]
        if let chatID { conditions.append("cmj.chat_id = \(chatID)") }
        let rows = try fetchMessages(
            where: conditions.joined(separator: " AND "), order: "m.ROWID ASC", bindings: [.integer(rowID), .integer(Int64(limit))], leftJoinChats: true)
        return try complete(rows, reactionChats: Array(Set(rows.compactMap(\.chatID))))
    }

    /// The addresses in conversation `chatID`, read now rather than from the cache, for a
    /// conversation a send has just started.
    public func currentParticipants(ofChat chatID: Int64) throws -> [String] {
        try database.query(
            "SELECT h.id FROM chat_handle_join chj JOIN handle h ON h.ROWID = chj.handle_id WHERE chj.chat_id = ?", [.integer(chatID)]
        ) { $0.string(0) ?? "" }
    }

    /// One message by id, for message references and delivery and read receipts. Nil for a
    /// reaction, which is folded onto the message it reacts to; see `reactionTarget(id:)`.
    public func message(id: Int64) throws -> Message? {
        let rows = try fetchMessages(
            where: "m.ROWID = ? AND \(Self.notReaction)", order: "m.ROWID", bindings: [.integer(id), .integer(1)], leftJoinChats: true)
        if let chatID = rows.first?.chatID, excludedChatIDs.contains(chatID) { return nil }
        return try complete(rows, reactionChats: rows.compactMap(\.chatID)).first
    }

    /// One message by GUID, such as a reply's `reply_to` or a reaction's `target`.
    public func message(guid: String) throws -> Message? {
        try messages(guids: [guid]).first
    }

    /// The GUID of the message that the reaction with id `id` reacts to. Nil when `id` is
    /// not a reaction tincan may read.
    public func reactionTarget(id: Int64) throws -> String? {
        try reactionTarget(where: "m.ROWID = ?", .integer(id))
    }

    /// The GUID of the message that the reaction with GUID `guid` reacts to.
    public func reactionTarget(guid: String) throws -> String? {
        try reactionTarget(where: "m.guid = ?", .text(guid))
    }

    private func reactionTarget(where condition: String, _ binding: SQLiteValue) throws -> String? {
        let conditions = [condition, Self.isReaction] + (exclusionCondition.map { [$0] } ?? [])
        let targets = try database.query(
            """
            SELECT m.associated_message_guid FROM message m WHERE \(conditions.joined(separator: " AND ")) LIMIT 1
            """, [binding]
        ) { $0.nonEmptyString(0) }
        return targets.first.flatMap { $0 }.map { Self.parseAssociatedGUID($0).guid }
    }

    /// Reply parents pass through the same exclusions as the messages themselves. Decode
    /// only these rows, without completing their replies, so cycles cannot recurse.
    private func replyParents(guids: Set<String>) throws -> [String: RawMessage] {
        guard !guids.isEmpty else { return [:] }
        let placeholders = Array(repeating: "?", count: guids.count).joined(separator: ",")
        let rows = try fetchMessages(
            where: "m.guid IN (\(placeholders)) AND \(Self.notReaction)", order: "m.ROWID",
            bindings: guids.map { .text($0) } + [.integer(Int64.max)], leftJoinChats: true)
        return Dictionary(rows.map { ($0.guid, $0) }, uniquingKeysWith: { first, _ in first })
    }

    // MARK: Row decoding

    static let reactionTypes = "(2000,2001,2002,2003,2004,2005,2006,2007,3000,3001,3002,3003,3004,3005,3006,3007,1000)"
    static let notReaction = "m.associated_message_type NOT IN \(reactionTypes)"
    static let isReaction = "m.associated_message_type IN \(reactionTypes)"
    /// The GUID a reaction row targets, in SQL, as `parseAssociatedGUID` reads it:
    /// `p:1/GUID` and `bp:GUID` both target GUID.
    static let reactionTarget = """
        (CASE WHEN m.associated_message_guid GLOB 'p:*/*' \
        THEN substr(m.associated_message_guid, instr(m.associated_message_guid, '/') + 1) \
        WHEN m.associated_message_guid GLOB 'bp:*' THEN substr(m.associated_message_guid, 4) \
        ELSE m.associated_message_guid END)
        """

    private func optional(_ column: String, _ fallback: String = "NULL") -> String {
        messageColumns.contains(column) ? "m.\(column)" : fallback
    }

    private lazy var selectColumns: String = [
        "m.ROWID", "m.guid", "m.text", "m.attributedBody", "m.handle_id", "m.is_from_me", "m.date", "m.service",
        optional("date_read", "0"), optional("date_delivered", "0"), optional("is_sent", "m.is_from_me"), optional("is_delivered", "0"),
        optional("error", "0"), optional("is_read", "0"), optional("item_type", "0"), optional("group_action_type", "0"),
        optional("other_handle", "0"), optional("group_title"), optional("balloon_bundle_id"), optional("is_audio_message", "0"),
        optional("thread_originator_guid"), optional("date_edited", "0"), optional("date_retracted", "0"),
        optional("message_summary_info"), optional("subject"), optional("expressive_send_style_id"),
        optional("associated_message_type", "0"), "cmj.chat_id",
    ].joined(separator: ", ")

    private func fetchMessages(where condition: String, order: String, bindings: [SQLiteValue], leftJoinChats: Bool = false) throws -> [RawMessage] {
        let join = leftJoinChats ? "LEFT JOIN" : "JOIN"
        // Exclusions apply here, not at each call site, so no query can forget them.
        let filtered = exclusionCondition.map { "(\(condition)) AND \($0)" } ?? condition
        return try database.query(
            """
            SELECT \(selectColumns) FROM message m \(join) chat_message_join cmj ON cmj.message_id = m.ROWID
            WHERE \(filtered) ORDER BY \(order) LIMIT ?
            """, bindings
        ) { RawMessage(row: $0) }
    }

    /// Adds senders, attachments and reactions to decoded rows.
    private func complete(_ rows: [RawMessage], reactionChats: [Int64]) throws -> [Message] {
        guard !rows.isEmpty else { return [] }
        let handles = try handles()
        let attachments = try attachments(forMessages: rows.map(\.rowID))
        let reactions = try reactions(forTargets: Set(rows.map(\.guid)), inChats: reactionChats, since: rows.map(\.date).min())
        let quoted = try replyParents(guids: Set(rows.compactMap(\.replyTarget)))
        return try rows.map { raw in
            var message = try raw.message(
                sender: raw.isFromMe ? nil : author(handleID: raw.handleID, chatID: raw.chatID),
                attachments: attachments[raw.rowID] ?? [],
                reactions: reactions[raw.guid] ?? [],
                otherHandle: handles[raw.otherHandle]?.address
            )
            message.sentByTincan = raw.isFromMe && sentByTincan.contains(raw.guid)
            if let parent = raw.replyTarget.flatMap({ quoted[$0] }) {
                message.replyToID = parent.rowID
                if !parent.body.text.isEmpty { message.replyToPreview = Message.ReplyPreview(text: parent.body.text) }
            }
            return message
        }
    }

    private func attachments(forMessages ids: [Int64]) throws -> [Int64: [Attachment]] {
        guard !ids.isEmpty else { return [:] }
        let emojiDescription = attachmentColumns.contains("emoji_image_short_description") ? "a.emoji_image_short_description" : "NULL"
        let emojiIdentifier = attachmentColumns.contains("emoji_image_content_identifier") ? "a.emoji_image_content_identifier" : "NULL"
        let hidden = attachmentColumns.contains("hide_attachment") ? "a.hide_attachment" : "0"
        var result: [Int64: [Attachment]] = [:]
        try database.forEach(
            """
            SELECT maj.message_id, a.guid, a.transfer_name, a.mime_type, a.uti, a.total_bytes, a.filename, a.is_sticker,
                   \(emojiDescription), \(emojiIdentifier), \(hidden)
            FROM message_attachment_join maj JOIN attachment a ON a.ROWID = maj.attachment_id
            WHERE maj.message_id IN (\(ids.map(String.init).joined(separator: ",")))
            ORDER BY maj.message_id, a.ROWID
            """
        ) { row in
            guard let messageID = row.int64(0) else { return true }
            // Messages hides link-preview images and similar payloads; they aren't attachments.
            if row.bool(10) { return true }
            let path = row.nonEmptyString(6).map { NSString(string: $0).expandingTildeInPath }
            let attachment = Attachment(
                guid: row.string(1) ?? "",
                name: row.nonEmptyString(2),
                mimeType: row.nonEmptyString(3),
                uti: row.nonEmptyString(4),
                bytes: row.int64(5) ?? 0,
                path: path.flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil },
                isSticker: row.bool(7),
                isEmojiImage: row.nonEmptyString(9) != nil,
                summary: row.nonEmptyString(8)
            )
            result[messageID, default: []].append(attachment)
            return true
        }
        return result
    }

    /// Current reactions per target GUID: later removals cancel earlier additions, and each
    /// person keeps one tapback per message part. Stickers placed on a bubble (type 1000)
    /// add up instead. Reactions only exist inside a chat, so rows without one have none.
    private func reactions(forTargets targets: Set<String>, inChats chatIDs: [Int64], since: Date?) throws -> [String: [Reaction]] {
        guard !targets.isEmpty, !chatIDs.isEmpty else { return [:] }
        let emoji = messageColumns.contains("associated_message_emoji") ? "m.associated_message_emoji" : "NULL"
        var conditions = [Self.isReaction, "cmj.chat_id IN (\(chatIDs.map(String.init).joined(separator: ",")))"]
        if let exclusion = exclusionCondition { conditions.append(exclusion) }
        var bindings: [SQLiteValue] = []
        if let since {
            // Each device stamps its own rows, so a reaction can predate its target by the
            // difference between two clocks. A day of margin covers any clock that is roughly right.
            conditions.append("m.date >= ?")
            bindings.append(.integer(self.dateValue(since.addingTimeInterval(-86_400))))
        }
        struct Key: Hashable {
            let target: String
            let part: Int
            let reactor: String
            let sticker: Int64?
        }
        var current: [Key: Reaction] = [:]
        try database.forEach(
            """
            SELECT m.associated_message_guid, m.associated_message_type, \(emoji), m.is_from_me, m.handle_id, m.date, cmj.chat_id, m.ROWID
            FROM message m JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
            WHERE \(conditions.joined(separator: " AND ")) ORDER BY m.date ASC, m.ROWID ASC
            """, bindings
        ) { row in
            let (target, part) = Self.parseAssociatedGUID(row.string(0) ?? "")
            guard targets.contains(target) else { return true }
            let type = row.int(1) ?? 0
            let from = row.bool(3) ? nil : try author(handleID: row.int64(4) ?? 0, chatID: row.int64(6))
            // Someone Messages did not record: leave the reaction out rather than call it yours.
            if !row.bool(3), from == nil { return true }
            let key = Key(target: target, part: part, reactor: from ?? "me", sticker: type == 1000 ? row.int64(7) : nil)
            if (3000...3007).contains(type) {
                if let existing = current[key], existing.kind == Self.reactionKind(type - 1000) { current[key] = nil }
                return true
            }
            guard let kind = Self.reactionKind(type) else { return true }
            current[key] = Reaction(
                kind: kind,
                emoji: row.nonEmptyString(2),
                from: from,
                at: AppleTime.messageDate(row.int64(5)) ?? Date(timeIntervalSinceReferenceDate: 0),
                part: part
            )
            return true
        }
        var result: [String: [Reaction]] = [:]
        for (key, reaction) in current { result[key.target, default: []].append(reaction) }
        return result.mapValues { $0.sorted { $0.at < $1.at } }
    }

    static func reactionKind(_ type: Int) -> Reaction.Kind? {
        switch type {
        case 2000: return .love
        case 2001: return .like
        case 2002: return .dislike
        case 2003: return .laugh
        case 2004: return .emphasize
        case 2005: return .question
        case 2006: return .emoji
        case 2007, 1000: return .sticker
        default: return nil
        }
    }

    /// `p:1/GUID` targets part 1, `bp:GUID` targets a balloon (part 0), a bare GUID part 0.
    static func parseAssociatedGUID(_ value: String) -> (guid: String, part: Int) {
        if value.hasPrefix("p:"), let slash = value.firstIndex(of: "/") {
            let part = Int(value[value.index(value.startIndex, offsetBy: 2)..<slash]) ?? 0
            return (String(value[value.index(after: slash)...]), part)
        }
        if value.hasPrefix("bp:") { return (String(value.dropFirst(3)), 0) }
        return (value, 0)
    }

    static func readReceiptSetting(_ data: Data?) -> Bool? {
        guard let data, !data.isEmpty,
            let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        return plist["EnableReadReceiptForChat"] as? Bool
    }
}

/// One `message` row before senders, attachments and reactions are attached.
private struct RawMessage {
    let rowID: Int64
    let guid: String
    let body: MessageBody
    let handleID: Int64
    let isFromMe: Bool
    let date: Date
    let service: MessageService
    let dateRead: Date?
    let dateDelivered: Date?
    let isSent: Bool
    let isDelivered: Bool
    let error: Int
    let isRead: Bool
    let itemType: Int
    let groupActionType: Int
    let otherHandle: Int64
    let groupTitle: String?
    let balloonBundleID: String?
    let isAudio: Bool
    let threadOriginator: String?
    let dateEdited: Date?
    let dateRetracted: Date?
    let summaryInfo: [String: Any]?
    let subject: String?
    let expressiveEffect: String?
    let associatedType: Int
    let chatID: Int64?

    init(row: SQLiteRow) {
        rowID = row.int64(0) ?? 0
        guid = row.string(1) ?? ""
        body = MessageBody.decode(text: row.string(2), attributedBody: row.data(3))
        handleID = row.int64(4) ?? 0
        isFromMe = row.bool(5)
        date = AppleTime.messageDate(row.int64(6)) ?? Date(timeIntervalSinceReferenceDate: 0)
        service = MessageService(databaseValue: row.string(7))
        dateRead = AppleTime.messageDate(row.int64(8))
        dateDelivered = AppleTime.messageDate(row.int64(9))
        isSent = row.bool(10)
        isDelivered = row.bool(11)
        error = row.int(12) ?? 0
        isRead = row.bool(13)
        itemType = row.int(14) ?? 0
        groupActionType = row.int(15) ?? 0
        otherHandle = row.int64(16) ?? 0
        groupTitle = row.nonEmptyString(17)
        balloonBundleID = row.nonEmptyString(18)
        isAudio = row.bool(19)
        threadOriginator = row.nonEmptyString(20)
        dateEdited = AppleTime.messageDate(row.int64(21))
        dateRetracted = AppleTime.messageDate(row.int64(22))
        summaryInfo = row.data(23).flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] }
        subject = row.nonEmptyString(24)
        expressiveEffect = row.nonEmptyString(25)
        associatedType = row.int(26) ?? 0
        chatID = row.int64(27)
    }

    /// Only thread metadata establishes an inline reply. `reply_to_guid` can point at
    /// the preceding message even without a reply, and associations also serve app data
    /// and reactions. Neither is evidence that the person quoted another message.
    var replyTarget: String? {
        guard let threadOriginator else { return nil }
        let guid = MessagesDatabase.parseAssociatedGUID(threadOriginator).guid
        return guid.isEmpty ? nil : guid
    }

    func message(sender: String?, attachments: [Attachment], reactions: [Reaction], otherHandle: String?) -> Message {
        let editedParts = (summaryInfo?["ep"] as? [Any])?.count ?? 0
        let unsentParts = ((summaryInfo?["rp"] as? [Any]) ?? []).compactMap { ($0 as? NSNumber)?.intValue }
        let visibleAttachments = attachments.filter { $0.category != "app_data" }
        let hasContent = !body.text.isEmpty || !visibleAttachments.isEmpty
        return Message(
            id: rowID,
            guid: guid,
            chatID: chatID,
            date: date,
            isFromMe: isFromMe,
            sender: sender,
            service: service,
            kind: kind,
            body: body,
            attachments: visibleAttachments,
            reactions: reactions,
            replyToGUID: replyTarget,
            // Messages also sets date_edited when a part is unsent; that is not an edit.
            isEdited: editedParts > 0 || (dateEdited != nil && unsentParts.isEmpty && dateRetracted == nil),
            unsentParts: unsentParts,
            isUnsent: (dateRetracted != nil || !unsentParts.isEmpty) && !hasContent,
            event: event(otherHandle: otherHandle),
            appName: appName,
            subject: subject,
            expressiveEffect: expressiveEffect.map(Self.effectName),
            deliveredAt: isFromMe ? (dateDelivered ?? (isDelivered ? date : nil)) : nil,
            readAt: isFromMe ? dateRead : nil,
            isSent: isSent,
            errorCode: error,
            isRead: isFromMe ? true : isRead
        )
    }

    private var kind: MessageKind {
        if itemType != 0 { return .event }
        if isAudio { return .audio }
        if balloonBundleID == "com.apple.messages.URLBalloonProvider" { return .link }
        if balloonBundleID != nil || associatedType == 2 || associatedType == 3 { return .app }
        return .message
    }

    private var appName: String? {
        guard let balloonBundleID, balloonBundleID != "com.apple.messages.URLBalloonProvider" else { return nil }
        let bundle = balloonBundleID.split(separator: ":").last.map(String.init) ?? balloonBundleID
        let known: [String: String] = [
            "com.gamerdelights.gamepigeon.ext": "GamePigeon",
            "com.apple.findmy.FindMyMessagesApp": "Find My",
            "com.apple.PassbookUIService.PeerPaymentMessagesExtension": "Apple Cash",
            "com.apple.messages.Polls": "Poll",
            "com.apple.family.InviteMessageBubbleExtension": "Family Sharing",
            "com.apple.SafetyMonitorApp.SafetyMonitorMessages": "Check In",
            "com.apple.mobileslideshow.PhotosMessagesApp": "Photos",
            "com.apple.messages.chatbot": "Business Chat",
        ]
        return known[bundle] ?? bundle
    }

    private func event(otherHandle: String?) -> ConversationEvent? {
        switch itemType {
        case 0: return nil
        case 1: return ConversationEvent(kind: groupActionType == 1 ? .removed : .added, subject: otherHandle, title: nil)
        case 2: return ConversationEvent(kind: .renamed, subject: nil, title: groupTitle)
        case 3:
            switch groupActionType {
            case 0: return ConversationEvent(kind: .left, subject: nil, title: nil)
            default: return ConversationEvent(kind: .photoChanged, subject: nil, title: nil)
            }
        default: return ConversationEvent(kind: .other, subject: otherHandle, title: groupTitle)
        }
    }

    private static func effectName(_ identifier: String) -> String {
        let names: [String: String] = [
            "com.apple.MobileSMS.expressivesend.impact": "slam",
            "com.apple.MobileSMS.expressivesend.loud": "loud",
            "com.apple.MobileSMS.expressivesend.gentle": "gentle",
            "com.apple.MobileSMS.expressivesend.invisibleink": "invisible_ink",
            "com.apple.messages.effect.CKConfettiEffect": "confetti",
            "com.apple.messages.effect.CKFireworksEffect": "fireworks",
            "com.apple.messages.effect.CKHappyBirthdayEffect": "balloons",
            "com.apple.messages.effect.CKHeartEffect": "love",
            "com.apple.messages.effect.CKLasersEffect": "lasers",
            "com.apple.messages.effect.CKShootingStarEffect": "celebration",
            "com.apple.messages.effect.CKSparklesEffect": "sparkles",
            "com.apple.messages.effect.CKSpotlightEffect": "spotlight",
            "com.apple.messages.effect.CKEchoEffect": "echo",
        ]
        return names[identifier] ?? identifier
    }
}
