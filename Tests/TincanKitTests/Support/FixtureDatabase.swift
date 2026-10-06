import Foundation
import SQLite3
import TincanKit

struct FixtureError: Error, CustomStringConvertible {
    let description: String
}

/// A writable SQLite file in its own temporary directory, so every test gets a fresh database.
///
/// All fixture directories live under one directory per test process, which is removed when
/// the process exits. Files are not deleted when a fixture is released, because a database
/// opened from the fixture may still be reading it (Swift can release the fixture right
/// after its last use).
///
/// tincan itself only ever opens these databases read-only; fixtures are the one place in
/// this repository that writes to a Messages or call history schema.
///
/// Sendable so a fake Messages app can write from another thread: SQLite serializes the
/// connection (`SQLITE_OPEN_FULLMUTEX`), and the column cache is behind a lock.
final class FixtureDatabase: @unchecked Sendable {
    let directory: URL
    let path: String
    private var handle: OpaquePointer?
    private let cacheLock = NSLock()
    private var columnCache: [String: Set<String>] = [:]

    init(fileName: String, schema: [String]) throws {
        directory = Self.root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        path = directory.appendingPathComponent(fileName).path
        // Serialized: a fake Messages app may write from another thread while a test runs.
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            throw FixtureError(description: "could not create \(path)")
        }
        // Tests write while tincan reads; wait out brief locks instead of failing the write.
        sqlite3_busy_timeout(handle, 5_000)
        // Fixtures are disposable: skip the journal file and fsyncs so hundreds of small
        // inserts across parallel tests stay fast.
        try execute("PRAGMA journal_mode = MEMORY")
        try execute("PRAGMA synchronous = OFF")
        try execute("BEGIN")
        for statement in schema { try execute(statement) }
        try execute("COMMIT")
    }

    deinit {
        sqlite3_close(handle)
    }

    /// `$TMPDIR/tincan-tests-<pid>`, removed when the test process exits.
    private static let root: URL = {
        atexit { try? FileManager.default.removeItem(at: FixtureDatabase.root) }
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("tincan-tests-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
    }()

    func execute(_ sql: String) throws {
        var message: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &message) == SQLITE_OK else {
            let text = message.map { String(cString: $0) } ?? "unknown error"
            sqlite3_free(message)
            throw FixtureError(description: "\(text) in: \(sql)")
        }
    }

    /// Inserts one row and returns its rowid. Columns the table does not have are skipped,
    /// so the same fixture code fills both current and reduced (older) schemas.
    @discardableResult
    func insert(into table: String, _ values: [String: SQLiteValue]) throws -> Int64 {
        let available = try columns(of: table)
        let pairs = values.filter { available.contains($0.key) }.sorted { $0.key < $1.key }
        let sql =
            pairs.isEmpty
            ? "INSERT INTO \(table) DEFAULT VALUES"
            : "INSERT INTO \(table) (\(pairs.map(\.key).joined(separator: ", "))) VALUES (\(pairs.map { _ in "?" }.joined(separator: ", ")))"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw FixtureError(description: "\(lastError) in: \(sql)")
        }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, pair) in pairs.enumerated() {
            let index = Int32(offset + 1)
            switch pair.value {
            case .null: sqlite3_bind_null(statement, index)
            case .integer(let value): sqlite3_bind_int64(statement, index, value)
            case .real(let value): sqlite3_bind_double(statement, index, value)
            case .text(let value): sqlite3_bind_text(statement, index, value, -1, transient)
            case .blob(let data):
                _ = data.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32($0.count), transient) }
            }
        }
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw FixtureError(description: "\(lastError) in: \(sql)")
        }
        return sqlite3_last_insert_rowid(handle)
    }

    /// Removes columns the way an older macOS release would lack them. Indexes that mention a
    /// removed column are dropped first, because SQLite refuses to drop indexed columns.
    func dropColumns(_ names: [String], from table: String) throws {
        for name in names {
            var indexes: [String] = []
            var statement: OpaquePointer?
            let lookup = "SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = ? AND sql LIKE ?"
            guard sqlite3_prepare_v2(handle, lookup, -1, &statement, nil) == SQLITE_OK else {
                throw FixtureError(description: lastError)
            }
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            sqlite3_bind_text(statement, 1, table, -1, transient)
            sqlite3_bind_text(statement, 2, "%\(name)%", -1, transient)
            while sqlite3_step(statement) == SQLITE_ROW {
                indexes.append(String(cString: sqlite3_column_text(statement, 0)))
            }
            sqlite3_finalize(statement)
            for index in indexes { try execute("DROP INDEX \(index)") }
            try execute("ALTER TABLE \(table) DROP COLUMN \(name)")
        }
        cacheLock.withLock { columnCache[table] = nil }
    }

    func columns(of table: String) throws -> Set<String> {
        if let cached = cacheLock.withLock({ columnCache[table] }) { return cached }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "SELECT name FROM pragma_table_info(?)", -1, &statement, nil) == SQLITE_OK else {
            throw FixtureError(description: lastError)
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, table, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        var names = Set<String>()
        while sqlite3_step(statement) == SQLITE_ROW {
            names.insert(String(cString: sqlite3_column_text(statement, 0)))
        }
        cacheLock.withLock { columnCache[table] = names }
        return names
    }

    private var lastError: String { String(cString: sqlite3_errmsg(handle)) }
}

extension Date {
    /// Fixture time: `minutes` after an arbitrary fixed moment in September 2025. Whole
    /// seconds survive the round trip through Apple's nanosecond timestamps exactly.
    static func minute(_ minutes: Int) -> Date {
        Date(timeIntervalSinceReferenceDate: 780_000_000 + TimeInterval(minutes * 60))
    }
}
