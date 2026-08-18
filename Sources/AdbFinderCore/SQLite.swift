import Foundation
import SQLite3

/// Tells SQLite our bound bytes may be freed the moment `bind` returns, so it
/// must copy them. Getting this wrong produces use-after-free crashes that look
/// like data corruption.
private let transientDestructor = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// A minimal wrapper over the system SQLite, with no external dependency.
///
/// Deliberately thin: this exists to make prepared statements and transactions
/// ergonomic, not to be an ORM.
final class SQLiteDatabase {
    private var handle: OpaquePointer?
    private var statementCache: [String: OpaquePointer] = [:]

    init(path: String) throws {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open \(path)"
            sqlite3_close_v2(db)
            throw CoreError.database(message, SQLITE_CANTOPEN)
        }
        handle = db

        // WAL lets the container app read diagnostics while the extension
        // writes. `foreign_keys` is off by default in SQLite and we rely on it.
        try execute("PRAGMA journal_mode = WAL")
        try execute("PRAGMA foreign_keys = ON")
        try execute("PRAGMA synchronous = NORMAL")
        try execute("PRAGMA busy_timeout = 5000")
    }

    deinit {
        for (_, statement) in statementCache { sqlite3_finalize(statement) }
        sqlite3_close_v2(handle)
    }

    // MARK: - Errors

    private func fail(_ code: Int32) -> CoreError {
        CoreError.database(String(cString: sqlite3_errmsg(handle)), code)
    }

    // MARK: - Statements

    /// Statements are cached because reconciliation prepares the same handful of
    /// queries thousands of times per directory.
    private func statement(_ sql: String) throws -> OpaquePointer {
        if let cached = statementCache[sql] {
            sqlite3_reset(cached)
            sqlite3_clear_bindings(cached)
            return cached
        }
        var prepared: OpaquePointer?
        let code = sqlite3_prepare_v2(handle, sql, -1, &prepared, nil)
        guard code == SQLITE_OK, let prepared else { throw fail(code) }
        statementCache[sql] = prepared
        return prepared
    }

    private func bind(_ values: [SQLiteValue], to statement: OpaquePointer) throws {
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let code: Int32
            switch value {
            case .null:
                code = sqlite3_bind_null(statement, index)
            case .integer(let number):
                code = sqlite3_bind_int64(statement, index, number)
            case .text(let string):
                code = sqlite3_bind_text(statement, index, string, -1, transientDestructor)
            case .blob(let data):
                code = data.isEmpty
                    ? sqlite3_bind_zeroblob(statement, index, 0)
                    : data.withUnsafeBytes {
                        sqlite3_bind_blob(statement, index, $0.baseAddress, Int32(data.count), transientDestructor)
                    }
            }
            guard code == SQLITE_OK else { throw fail(code) }
        }
    }

    /// Runs a statement that returns no rows.
    func run(_ sql: String, _ values: SQLiteValue...) throws {
        try run(sql, values)
    }

    func run(_ sql: String, _ values: [SQLiteValue]) throws {
        let statement = try self.statement(sql)
        try bind(values, to: statement)
        let code = sqlite3_step(statement)
        guard code == SQLITE_DONE || code == SQLITE_ROW else { throw fail(code) }
        sqlite3_reset(statement)
    }

    /// Runs a query, mapping each row.
    func query<T>(_ sql: String, _ values: [SQLiteValue] = [], row: (SQLiteRow) throws -> T) throws -> [T] {
        let statement = try self.statement(sql)
        try bind(values, to: statement)
        defer { sqlite3_reset(statement) }

        var results: [T] = []
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_ROW {
                results.append(try row(SQLiteRow(statement: statement)))
            } else if code == SQLITE_DONE {
                return results
            } else {
                throw fail(code)
            }
        }
    }

    func queryOne<T>(_ sql: String, _ values: [SQLiteValue] = [], row: (SQLiteRow) throws -> T) throws -> T? {
        try query(sql, values, row: row).first
    }

    /// Multi-statement DDL. Not cached, not parameterised.
    func execute(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        let code = sqlite3_exec(handle, sql, nil, nil, &error)
        guard code == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(error)
            throw CoreError.database(message, code)
        }
    }

    var lastInsertedID: Int64 { sqlite3_last_insert_rowid(handle) }

    // MARK: - Transactions

    /// Reconciliation must be all-or-nothing: a half-applied directory would
    /// leave identifiers pointing at names that no longer exist.
    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }
}

enum SQLiteValue {
    case null
    case integer(Int64)
    case text(String)
    case blob(Data)

    static func integer(_ value: Int) -> SQLiteValue { .integer(Int64(value)) }
    static func boolean(_ value: Bool) -> SQLiteValue { .integer(value ? 1 : 0) }

    static func optionalInteger(_ value: UInt64?) -> SQLiteValue {
        guard let value else { return .null }
        return .integer(Int64(bitPattern: value))
    }
}

struct SQLiteRow {
    let statement: OpaquePointer

    func int64(_ index: Int32) -> Int64 { sqlite3_column_int64(statement, index) }
    func int(_ index: Int32) -> Int { Int(sqlite3_column_int64(statement, index)) }
    func bool(_ index: Int32) -> Bool { sqlite3_column_int64(statement, index) != 0 }

    func string(_ index: Int32) -> String {
        guard let pointer = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: pointer)
    }

    func isNull(_ index: Int32) -> Bool {
        sqlite3_column_type(statement, index) == SQLITE_NULL
    }

    func optionalUInt64(_ index: Int32) -> UInt64? {
        isNull(index) ? nil : UInt64(bitPattern: sqlite3_column_int64(statement, index))
    }
}
