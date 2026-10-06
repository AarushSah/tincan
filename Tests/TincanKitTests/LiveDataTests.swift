import Foundation
import Testing

@testable import TincanKit

/// Read-only checks against this Mac's real Messages database. They print counts only and
/// never message content, and honor the exclusions in tincan's config like tincan does, so
/// excluded conversations are never decoded. Run with
/// `TINCAN_LIVE_TESTS=1 swift test --filter Live` from a terminal that has Full Disk Access.
@Suite("Live data", .enabled(if: ProcessInfo.processInfo.environment["TINCAN_LIVE_TESTS"] == "1"))
struct LiveDataTests {
    /// This Mac's Messages database without the conversations the config excludes.
    private func messages() throws -> MessagesDatabase {
        try MessagesDatabase(excluding: try Config.load().excludedChats)
    }

    @Test func everyMessageBodyDecodes() throws {
        let messages = try messages()
        var counts: [MessageBody.Source: Int] = [:]
        var attachmentPlaceholders = 0
        var emptyWithBlob = 0
        try messages.database.forEach(
            "SELECT m.text, m.attributedBody FROM message m LEFT JOIN chat_message_join cmj ON cmj.message_id = m.ROWID WHERE \(messages.exclusionCondition ?? "1")"
        ) { row in
            let body = MessageBody.decode(text: row.string(0), attributedBody: row.data(1))
            counts[body.source, default: 0] += 1
            attachmentPlaceholders += body.attachmentGUIDs.count
            if body.source == .none, row.data(1)?.isEmpty == false { emptyWithBlob += 1 }
            return true
        }
        print("decode sources:", counts.map { "\($0.key.rawValue)=\($0.value)" }.sorted().joined(separator: " "))
        print("attachment placeholders:", attachmentPlaceholders, "undecodable blobs:", emptyWithBlob)
        #expect(counts[.recovered, default: 0] + emptyWithBlob < 50)
    }

    @Test func conversationsAndMessagesLoad() throws {
        let messages = try messages()
        let start = Date()
        let summaries = try messages.chatSummaries(limit: 25)
        let listTime = Date().timeIntervalSince(start)
        #expect(summaries.count == 25)
        var total = 0
        var reactions = 0
        var fromMe = 0
        var withSender = 0
        var events = 0
        var edited = 0
        var unsent = 0
        var replies = 0
        var attachments = 0
        var kinds: [String: Int] = [:]
        let readStart = Date()
        for summary in summaries {
            let page = try messages.messages(inChats: [summary.chat.id], limit: 200)
            for message in page {
                total += 1
                reactions += message.reactions.count
                if message.isFromMe {
                    fromMe += 1
                    #expect(message.sender == nil)
                } else if message.sender != nil {
                    withSender += 1
                }
                if message.event != nil { events += 1 }
                if message.isEdited { edited += 1 }
                if message.isUnsent { unsent += 1 }
                if message.replyToGUID != nil { replies += 1 }
                attachments += message.attachments.count
                kinds[message.kind.rawValue, default: 0] += 1
            }
        }
        let readTime = Date().timeIntervalSince(readStart)
        print("chat list: \(String(format: "%.2f", listTime))s; read 25 chats: \(String(format: "%.2f", readTime))s")
        print(
            "messages \(total) fromMe \(fromMe) incomingWithSender \(withSender)/\(total - fromMe) reactions \(reactions) events \(events) edited \(edited) unsent \(unsent) replies \(replies) attachments \(attachments)"
        )
        print("kinds", kinds.sorted { $0.key < $1.key })
        let latest = try messages.latestRowID()
        let recent = try messages.messages(afterRowID: max(0, latest - 300), limit: 500)
        print("cursor read: \(recent.count) messages after rowid latest-300")
        #expect(recent.allSatisfy { $0.id > latest - 300 })
    }

    @Test func callHistoryLoads() throws {
        let history = try CallHistoryDatabase()
        let start = Date()
        let calls = try history.calls()
        let elapsed = Date().timeIntervalSince(start)
        var outcomes: [String: Int] = [:]
        var kinds: [String: Int] = [:]
        var e164 = 0
        var other = 0
        var group = 0
        for call in calls {
            outcomes["\(call.direction.rawValue)/\(call.outcome.rawValue)", default: 0] += 1
            kinds[call.kind.rawValue, default: 0] += 1
            if call.addresses.count > 1 { group += 1 }
            for address in call.addresses { if address.hasPrefix("+") { e164 += 1 } else { other += 1 } }
        }
        print(
            "calls \(calls.count) in \(String(format: "%.2f", elapsed))s; outcomes \(outcomes.sorted { $0.key < $1.key }); kinds \(kinds.sorted { $0.key < $1.key }); addresses e164 \(e164) other \(other); group \(group)"
        )
        #expect(!calls.isEmpty)
    }

    @Test func quickTextAgreesWithFullDecoding() throws {
        let messages = try messages()
        var rows = 0
        var differences = 0
        try messages.database.forEach(
            "SELECT m.text, m.attributedBody FROM message m LEFT JOIN chat_message_join cmj ON cmj.message_id = m.ROWID WHERE \(messages.exclusionCondition ?? "1")"
        ) { row in
            rows += 1
            let quick = MessageBody.quickText(text: row.string(0), attributedBody: row.data(1))
            let full = MessageBody.decode(text: row.string(0), attributedBody: row.data(1)).text
            if quick.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
                != full.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            {
                differences += 1
            }
            return true
        }
        print("quick text differs on \(differences) of \(rows) rows")
        #expect(differences * 1000 < rows)
    }
}
