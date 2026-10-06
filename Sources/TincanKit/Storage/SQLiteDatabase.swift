import Foundation
import SQLite3

/// A value bound to, or read from, a SQLite statement.
public enum SQLiteValue: Sendable, Equatable {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)
}

public enum SQLiteError: Error, CustomStringConvertible, Sendable {
    /// macOS privacy protection refused access. For Messages and call history this means
    /// the app that runs tincan doesn't have Full Disk Access.
    case accessDenied(path: String)
    case notFound(path: String)
    case open(path: String, message: String)
    case prepare(message: String, sql: String)
    case step(message: String)

    public var description: String {
        switch self {
        case .accessDenied(let path): return "macOS denied access to \(path)"
        case .notFound(let path): return "\(path) does not exist"
        case .open(let path, let message): return "could not open \(path): \(message)"
        case .prepare(let message, _): return "could not prepare query: \(message)"
        case .step(let message): return "query failed: \(message)"
        }
    }
}

/// A small read-only SQLite connection for the databases that Messages and the phone
/// system own. tincan never writes to them.
public final class SQLiteDatabase {
    public let path: String
    private var handle: OpaquePointer?
    /// The connection reads the database file as immutable while its `-wal` file is missing.
    private var snapshot = false
    private var columnCache: [String: [String]] = [:]

    /// Opens `path` read-only. Messages keeps its database in WAL mode, so the connection
    /// still sees rows that Messages has not checkpointed yet.
    ///
    /// Messages removes the `-wal` file at times, as when its database process quits, until
    /// it opens the database again. A read-only connection can't create that file, so its
    /// first read fails with `SQLITE_CANTOPEN`. Without a `-wal` file every committed change
    /// is in the database file itself, so tincan then reads that file as immutable, which
    /// needs no `-wal` or `-shm` file and creates neither. An immutable connection never sees
    /// later writes and may keep pages a checkpoint rewrites, so it serves one read only: see
    /// `reconnectIfSnapshot`.
    public init(path: String) throws {
        self.path = path
        try Self.checkReadable(path)
        (handle, snapshot) = try Self.connect(path)
    }

    deinit {
        sqlite3_close(handle)
    }

    /// Distinguishes "missing", "not permitted" and "readable" before SQLite hides the reason.
    static func checkReadable(_ path: String) throws {
        let descriptor = open(path, O_RDONLY)
        if descriptor >= 0 {
            close(descriptor)
            return
        }
        switch errno {
        case EPERM, EACCES: throw SQLiteError.accessDenied(path: path)
        case ENOENT, ENOTDIR: throw SQLiteError.notFound(path: path)
        default: throw SQLiteError.open(path: path, message: String(cString: strerror(errno)))
        }
    }

    // MARK: Queries

    /// Runs `sql` and maps every row. Use `?` placeholders for values.
    public func query<T>(_ sql: String, _ bindings: [SQLiteValue] = [], _ map: (SQLiteRow) throws -> T) throws -> [T] {
        try reconnectIfSnapshot()
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bind(bindings, to: statement)
        var results: [T] = []
        let row = SQLiteRow(statement: statement)
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_ROW {
                results.append(try map(row))
            } else if code == SQLITE_DONE {
                return results
            } else {
                throw stepError(code)
            }
        }
    }

    /// Runs `sql` and calls `body` for each row until it returns `false`.
    public func forEach(_ sql: String, _ bindings: [SQLiteValue] = [], _ body: (SQLiteRow) throws -> Bool) throws {
        try reconnectIfSnapshot()
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bind(bindings, to: statement)
        let row = SQLiteRow(statement: statement)
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_ROW {
                if try !body(row) { return }
            } else if code == SQLITE_DONE {
                return
            } else {
                throw stepError(code)
            }
        }
    }

    public func scalarInteger(_ sql: String, _ bindings: [SQLiteValue] = []) throws -> Int64? {
        try query(sql, bindings) { $0.int64(0) }.first ?? nil
    }

    // MARK: Schema

    /// Column names of `table`, in declaration order. Empty when the table is missing.
    /// Apple adds columns in most macOS releases, so queries check for optional columns
    /// instead of assuming one schema.
    public func columns(of table: String) throws -> [String] {
        if let cached = columnCache[table] { return cached }
        let names = try query("SELECT name FROM pragma_table_info(?)", [.text(table)]) { $0.string(0) ?? "" }
        columnCache[table] = names
        return names
    }

    public func hasColumn(_ column: String, in table: String) -> Bool {
        (try? columns(of: table).contains(column)) ?? false
    }

    public func hasTable(_ table: String) -> Bool {
        ((try? columns(of: table)) ?? []).isEmpty == false
    }

    // MARK: Internals

    /// Before each read on an immutable connection, connects again: normally once Messages
    /// has made a `-wal` file again, so `watch` and `send` see what it writes next, and
    /// otherwise as immutable afresh, so no page read before a checkpoint is reused after it.
    private func reconnectIfSnapshot() throws {
        guard snapshot else { return }
        let (connection, stillSnapshot) = try Self.connect(path)
        // A read inside `forEach` may still be stepping the old connection: close_v2 closes
        // it once that statement is finalized.
        sqlite3_close_v2(handle)
        (handle, snapshot) = (connection, stillSnapshot)
    }

    /// A connection to `path`, and whether it reads the database file as immutable because
    /// the `-wal` file is missing.
    private static func connect(_ path: String) throws -> (OpaquePointer, Bool) {
        do {
            return (try openConnection(path, immutable: false), false)
        } catch let failure as ConnectFailure {
            guard failure.code == SQLITE_CANTOPEN, !FileManager.default.fileExists(atPath: path + "-wal") else {
                throw failure.error
            }
            do {
                return (try openConnection(path, immutable: true), true)
            } catch let retry as ConnectFailure {
                throw retry.error
            }
        }
    }

    /// Why a connection could not be made: the error to report, and SQLite's result code.
    private struct ConnectFailure: Error {
        let code: Int32
        let error: SQLiteError
    }

    /// A read-only connection to `path`, proven by a cheap read: macOS privacy checks can
    /// allow the open and still refuse the file.
    private static func openConnection(_ path: String, immutable: Bool) throws -> OpaquePointer {
        var connection: OpaquePointer?
        let file = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        let uri = "file:" + file + (immutable ? "?mode=ro&immutable=1" : "?mode=ro")
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_NOMUTEX
        let code = sqlite3_open_v2(uri, &connection, flags, nil)
        guard code == SQLITE_OK, let connection else {
            let message = connection.map { String(cString: sqlite3_errmsg($0)) } ?? "error \(code)"
            sqlite3_close(connection)
            if code == SQLITE_AUTH || code == SQLITE_PERM { throw ConnectFailure(code: code, error: .accessDenied(path: path)) }
            throw ConnectFailure(code: code, error: .open(path: path, message: message))
        }
        sqlite3_busy_timeout(connection, 3_000)
        let probe = "PRAGMA schema_version"
        var statement: OpaquePointer?
        let prepared = sqlite3_prepare_v2(connection, probe, -1, &statement, nil)
        let result = prepared == SQLITE_OK ? sqlite3_step(statement) : prepared
        let message = String(cString: sqlite3_errmsg(connection))
        sqlite3_finalize(statement)
        guard result == SQLITE_ROW else {
            sqlite3_close(connection)
            if result == SQLITE_AUTH || result == SQLITE_PERM { throw ConnectFailure(code: result, error: .accessDenied(path: path)) }
            let error: SQLiteError = prepared == SQLITE_OK ? .step(message: message) : .prepare(message: message, sql: probe)
            throw ConnectFailure(code: result, error: error)
        }
        return connection
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        let code = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard code == SQLITE_OK, let statement else {
            if code == SQLITE_AUTH || code == SQLITE_PERM { throw SQLiteError.accessDenied(path: path) }
            throw SQLiteError.prepare(message: String(cString: sqlite3_errmsg(handle)), sql: sql)
        }
        return statement
    }

    private func stepError(_ code: Int32) -> SQLiteError {
        if code == SQLITE_AUTH || code == SQLITE_PERM { return .accessDenied(path: path) }
        return .step(message: String(cString: sqlite3_errmsg(handle)))
    }

    private func bind(_ values: [SQLiteValue], to statement: OpaquePointer) throws {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let code: Int32
            switch value {
            case .null: code = sqlite3_bind_null(statement, index)
            case .integer(let number): code = sqlite3_bind_int64(statement, index, number)
            case .real(let number): code = sqlite3_bind_double(statement, index, number)
            case .text(let text): code = sqlite3_bind_text(statement, index, text, -1, transient)
            case .blob(let data):
                code = data.withUnsafeBytes { buffer in
                    sqlite3_bind_blob(statement, index, buffer.baseAddress, Int32(buffer.count), transient)
                }
            }
            guard code == SQLITE_OK else {
                throw SQLiteError.prepare(message: String(cString: sqlite3_errmsg(handle)), sql: "binding \(index)")
            }
        }
    }
}

/// The current row of a running query. Only valid inside the mapping closure.
public struct SQLiteRow {
    fileprivate let statement: OpaquePointer

    public func name(_ index: Int) -> String {
        String(cString: sqlite3_column_name(statement, Int32(index)))
    }

    public func isNull(_ index: Int) -> Bool {
        sqlite3_column_type(statement, Int32(index)) == SQLITE_NULL
    }

    public func int64(_ index: Int) -> Int64? {
        isNull(index) ? nil : sqlite3_column_int64(statement, Int32(index))
    }

    public func int(_ index: Int) -> Int? {
        int64(index).map { Int($0) }
    }

    public func double(_ index: Int) -> Double? {
        isNull(index) ? nil : sqlite3_column_double(statement, Int32(index))
    }

    public func bool(_ index: Int) -> Bool {
        (int64(index) ?? 0) != 0
    }

    public func string(_ index: Int) -> String? {
        guard !isNull(index), let text = sqlite3_column_text(statement, Int32(index)) else { return nil }
        return String(cString: text)
    }

    /// Text with surrounding whitespace removed, or nil when empty.
    public func nonEmptyString(_ index: Int) -> String? {
        guard let value = string(index)?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    public func data(_ index: Int) -> Data? {
        guard !isNull(index) else { return nil }
        let count = Int(sqlite3_column_bytes(statement, Int32(index)))
        guard count > 0, let bytes = sqlite3_column_blob(statement, Int32(index)) else { return Data() }
        return Data(bytes: bytes, count: count)
    }
}
