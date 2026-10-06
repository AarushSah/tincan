import Foundation
import SQLite3
import Testing

@testable import TincanKit

@Suite("Apple timestamps")
struct AppleTimeTests {
    /// 2025-09-18 23:20:00 UTC.
    static let moment = Date(timeIntervalSinceReferenceDate: 780_000_000)

    @Test func messageDatesInNanosecondsAreRead() {
        #expect(AppleTime.messageDate(780_000_000_000_000_000) == Self.moment)
    }

    @Test func messageDatesInSecondsFromOldDatabasesAreRead() {
        #expect(AppleTime.messageDate(780_000_000) == Self.moment)
    }

    @Test func theUnitIsChosenByMagnitude() {
        // One hundred billion is the boundary: seconds at or below it, nanoseconds above.
        #expect(AppleTime.messageDate(100_000_000_000) == Date(timeIntervalSinceReferenceDate: 100_000_000_000))
        #expect(AppleTime.messageDate(100_000_000_001) == Date(timeIntervalSinceReferenceDate: 100.000000001))
    }

    @Test func missingMessageDatesAreNil() {
        #expect(AppleTime.messageDate(nil) == nil)
        #expect(AppleTime.messageDate(0) == nil)
        #expect(AppleTime.messageDate(-1) == nil)
    }

    @Test func messageValuesRoundTrip() {
        #expect(AppleTime.messageValue(Self.moment) == 780_000_000_000_000_000)
        let precise = Date(timeIntervalSinceReferenceDate: 780_000_000.25)
        #expect(AppleTime.messageDate(AppleTime.messageValue(precise)) == precise)
    }

    @Test func callDatesAreFractionalSeconds() {
        #expect(AppleTime.callDate(780_000_000.5) == Date(timeIntervalSinceReferenceDate: 780_000_000.5))
        #expect(AppleTime.callDate(AppleTime.callValue(Self.moment)) == Self.moment)
        #expect(AppleTime.callDate(nil) == nil)
        #expect(AppleTime.callDate(0) == nil)
    }
}

@Suite("SQLite access")
struct SQLiteDatabaseTests {
    @Test func aMissingFileIsReportedAsMissing() {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("tincan-missing-\(UUID().uuidString).db").path
        let error = #expect(throws: SQLiteError.self) { _ = try SQLiteDatabase(path: path) }
        guard case .notFound(let missing)? = error else {
            Issue.record("expected .notFound, got \(String(describing: error))")
            return
        }
        #expect(missing == path)
    }

    @Test func connectionsAreReadOnly() throws {
        let fixture = try MessagesFixture()
        let database = try SQLiteDatabase(path: fixture.path)
        #expect(throws: SQLiteError.self) {
            _ = try database.query("INSERT INTO handle (id, service) VALUES ('+14155550142', 'iMessage')") { _ in () }
        }
    }

    @Test func schemaQueriesReportTablesAndColumns() throws {
        let fixture = try MessagesFixture()
        let database = try SQLiteDatabase(path: fixture.path)
        #expect(database.hasTable("message"))
        #expect(!database.hasTable("no_such_table"))
        #expect(database.hasColumn("attributedBody", in: "message"))
        #expect(!database.hasColumn("no_such_column", in: "message"))
        #expect(try database.columns(of: "handle") == ["ROWID", "id", "country", "service", "uncanonicalized_id", "person_centric_id"])
    }

    @Test func rowsDecodeEveryValueType() throws {
        let fixture = try MessagesFixture()
        let database = try SQLiteDatabase(path: fixture.path)
        let row = try #require(
            try database.query(
                "SELECT ?, ?, ?, ?, ?, '  padded  ', ''",
                [.integer(42), .real(1.5), .text("text"), .blob(Data([1, 2, 3])), .null]
            ) { row in
                (row.int64(0), row.double(1), row.string(2), row.data(3), row.isNull(4), row.nonEmptyString(5), row.nonEmptyString(6), row.bool(0))
            }.first)
        #expect(row.0 == 42)
        #expect(row.1 == 1.5)
        #expect(row.2 == "text")
        #expect(row.3 == Data([1, 2, 3]))
        #expect(row.4)
        #expect(row.5 == "padded")
        #expect(row.6 == nil)
        #expect(row.7)
    }

    /// Messages removes `chat.db-wal` at times, as when its database process quits, and a
    /// read-only connection can't create it again: the database must still read, from the
    /// main file, and tincan must leave no file beside it.
    @Test func aWALDatabaseReadsWhileItsWALFileIsMissing() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tincan-wal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("chat.db").path
        var writer: OpaquePointer?
        try #require(sqlite3_open(path, &writer) == SQLITE_OK)
        for statement in [
            "PRAGMA journal_mode = WAL", "CREATE TABLE handle (id TEXT)",
            "INSERT INTO handle VALUES ('+14155550142'), ('+14155550143')", "PRAGMA wal_checkpoint(TRUNCATE)",
        ] {
            try #require(sqlite3_exec(writer, statement, nil, nil, nil) == SQLITE_OK)
        }
        sqlite3_close(writer)
        for sidecar in ["-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + sidecar) }

        let database = try SQLiteDatabase(path: path)
        #expect(try database.scalarInteger("SELECT COUNT(*) FROM handle") == 2)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["chat.db"])
    }

    /// `watch` and `send` keep one connection for their whole run. One made while the `-wal`
    /// file was missing must still see what Messages writes once it opens the database again,
    /// first into a new `-wal` file and then, after a checkpoint, into the database file.
    @Test func aConnectionMadeWhileTheWALFileIsMissingSeesLaterWrites() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tincan-wal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("chat.db").path
        func write(_ statements: [String]) throws {
            var writer: OpaquePointer?
            try #require(sqlite3_open(path, &writer) == SQLITE_OK)
            defer { sqlite3_close(writer) }
            for statement in statements { try #require(sqlite3_exec(writer, statement, nil, nil, nil) == SQLITE_OK) }
        }
        try write([
            "PRAGMA journal_mode = WAL", "CREATE TABLE handle (id TEXT)", "INSERT INTO handle VALUES ('+14155550142')", "PRAGMA wal_checkpoint(TRUNCATE)",
        ])
        for sidecar in ["-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + sidecar) }
        let database = try SQLiteDatabase(path: path)
        #expect(try database.scalarInteger("SELECT COUNT(*) FROM handle") == 1)

        // Messages writes again: into a new -wal file, which it keeps open.
        var messages: OpaquePointer?
        try #require(sqlite3_open(path, &messages) == SQLITE_OK)
        defer { sqlite3_close(messages) }
        try #require(sqlite3_exec(messages, "INSERT INTO handle VALUES ('+14155550143')", nil, nil, nil) == SQLITE_OK)
        #expect(try database.scalarInteger("SELECT COUNT(*) FROM handle") == 2)

        // A checkpoint moves the rows into the database file itself, rewriting its pages.
        for value in 144...199 {
            try #require(sqlite3_exec(messages, "INSERT INTO handle VALUES ('+14155550\(value)')", nil, nil, nil) == SQLITE_OK)
        }
        try #require(sqlite3_exec(messages, "PRAGMA wal_checkpoint(TRUNCATE)", nil, nil, nil) == SQLITE_OK)
        #expect(try database.scalarInteger("SELECT COUNT(*) FROM handle") == 58)
        #expect(try database.scalarInteger("SELECT COUNT(DISTINCT id) FROM handle") == 58)
    }

    @Test func forEachStopsWhenAskedTo() throws {
        let fixture = try MessagesFixture()
        for index in 1...5 { try fixture.addHandle("+1415555014\(index)") }
        let database = try SQLiteDatabase(path: fixture.path)
        var seen = 0
        try database.forEach("SELECT id FROM handle ORDER BY ROWID") { _ in
            seen += 1
            return seen < 2
        }
        #expect(seen == 2)
        #expect(try database.scalarInteger("SELECT COUNT(*) FROM handle") == 5)
    }
}

/// A read that fails once (the file is locked, briefly unreadable) must not be remembered as
/// an older schema that lacks optional columns.
@Suite("Busy databases")
struct BusyDatabaseTests {
    @Test func aFailedFirstReadIsNotMistakenForAMissingColumn() throws {
        let fixture = try MessagesFixture()
        let maya = try fixture.addHandle("+14155550142")
        let chat = try fixture.addChat("any;-;+14155550142", participants: [maya])
        let question = try fixture.addMessage("Dinner?", in: chat, from: .handle(maya), at: .minute(1))
        try fixture.addMessage("Yes", in: chat, from: .me, at: .minute(2)) { $0.threadOriginatorGUID = question.guid }
        let database = try fixture.open()

        try fixture.database.execute("BEGIN EXCLUSIVE")
        #expect(throws: (any Error).self) { try database.messages(inChats: [chat]) }
        try fixture.database.execute("COMMIT")

        let messages = try database.messages(inChats: [chat])
        #expect(messages.map(\.isRead) == [true, true])
        #expect(messages.last?.replyToGUID == question.guid)
    }

    @Test func aFailedFirstReadOfCallHistoryIsNotMistakenForMissingColumns() throws {
        let fixture = try CallHistoryFixture()
        try fixture.addCall(address: "+14155550142", at: .minute(1), answered: true, duration: 60)
        let history = try fixture.open()

        try fixture.database.execute("BEGIN EXCLUSIVE")
        #expect(throws: (any Error).self) { try history.calls() }
        try fixture.database.execute("COMMIT")

        let call = try #require(try history.calls().first)
        #expect(call.outcome == .answered)
        #expect(call.addresses == ["+14155550142"])
    }
}

@Suite("Empty databases")
struct EmptyDatabaseTests {
    @Test func everyReadWorksOnAnEmptyMessagesDatabase() throws {
        let database = try MessagesFixture().open(excluding: [1])
        #expect(try database.allChats().isEmpty)
        #expect(try database.chatSummaries(limit: nil).isEmpty)
        #expect(try database.messages(inChats: [1, 2], beforeMessage: 1).isEmpty)
        #expect(try database.messages(afterRowID: 0, limit: 10).isEmpty)
        #expect(try database.reactionRows(afterRowID: 0, limit: 10).isEmpty)
        #expect(try database.unreadMessages(limit: 10).isEmpty)
        #expect(try database.unreadCountByChat().isEmpty)
        #expect(try database.messageCounts(chatIDs: [2]).isEmpty)
        #expect(try database.search("anything", limit: 10).isEmpty)
        #expect(try database.messages(guids: ["missing"]).isEmpty)
        #expect(try database.message(id: 1) == nil)
        #expect(try database.outgoing(inChat: nil, afterRowID: 0).isEmpty)
        #expect(try database.firstOutgoingDate(inChat: 2, after: .minute(0)) == nil)
        #expect(try database.ownAddresses().isEmpty)
        #expect(try database.latestRowID() == 0)
        #expect(try database.rowID(before: .minute(0)) == 0)
    }

    @Test func callHistoryWithoutCallsHasNone() throws {
        #expect(try CallHistoryFixture().open().calls(missedOnly: true, addresses: ["+14155550142"]).isEmpty)
    }
}
