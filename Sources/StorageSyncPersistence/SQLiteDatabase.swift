import Foundation
import SQLite3

enum SQLiteValue {
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)
    case null
}

enum SQLiteDatabaseError: Error, CustomStringConvertible {
    case open(String)
    case prepare(String)
    case bind(String)
    case step(String)
    case execute(String)

    var description: String {
        switch self {
        case .open(let message): "Unable to open database: \(message)"
        case .prepare(let message): "Unable to prepare statement: \(message)"
        case .bind(let message): "Unable to bind value: \(message)"
        case .step(let message): "Unable to step statement: \(message)"
        case .execute(let message): "Unable to execute statement: \(message)"
        }
    }
}

final class SQLiteDatabase {
    private var handle: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let result = sqlite3_open_v2(
            url.path,
            &handle,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard result == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "Unknown SQLite error"
            sqlite3_close(handle)
            handle = nil
            throw SQLiteDatabaseError.open(message)
        }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )

        sqlite3_busy_timeout(handle, 10_000)
        try execute("PRAGMA journal_mode=WAL")
        try execute("PRAGMA synchronous=FULL")
        try execute("PRAGMA foreign_keys=ON")
        // Large manifest joins may spill while reconciling millions of paths.
        // Keep that spill on disk instead of letting SQLite grow the process
        // without bound.
        try execute("PRAGMA temp_store=FILE")
    }

    deinit {
        sqlite3_close(handle)
    }

    func execute(_ sql: String, bindings: [SQLiteValue] = []) throws {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bind(bindings, to: statement)
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE || result == SQLITE_ROW else {
            throw SQLiteDatabaseError.execute(errorMessage)
        }
    }

    func query(
        _ sql: String,
        bindings: [SQLiteValue] = [],
        row: (OpaquePointer) throws -> Void
    ) throws {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bind(bindings, to: statement)

        while true {
            let result = sqlite3_step(statement)
            switch result {
            case SQLITE_ROW:
                try row(statement)
            case SQLITE_DONE:
                return
            default:
                throw SQLiteDatabaseError.step(errorMessage)
            }
        }
    }

    func transaction(_ work: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            try work()
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func text(_ statement: OpaquePointer, column: Int32) -> String? {
        guard let pointer = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: pointer)
    }

    func blob(_ statement: OpaquePointer, column: Int32) -> Data? {
        let count = Int(sqlite3_column_bytes(statement, column))
        guard count > 0, let pointer = sqlite3_column_blob(statement, column) else {
            return count == 0 ? Data() : nil
        }
        return Data(bytes: pointer, count: count)
    }

    func integer(_ statement: OpaquePointer, column: Int32) -> Int64 {
        sqlite3_column_int64(statement, column)
    }

    func real(_ statement: OpaquePointer, column: Int32) -> Double {
        sqlite3_column_double(statement, column)
    }

    func isNull(_ statement: OpaquePointer, column: Int32) -> Bool {
        sqlite3_column_type(statement, column) == SQLITE_NULL
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw SQLiteDatabaseError.prepare(errorMessage)
        }
        return statement
    }

    private func bind(_ values: [SQLiteValue], to statement: OpaquePointer) throws {
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            switch value {
            case .integer(let value):
                result = sqlite3_bind_int64(statement, index, value)
            case .real(let value):
                result = sqlite3_bind_double(statement, index, value)
            case .text(let value):
                result = sqlite3_bind_text(statement, index, value, -1, transient)
            case .blob(let value):
                result = value.withUnsafeBytes { bytes in
                    sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(bytes.count), transient)
                }
            case .null:
                result = sqlite3_bind_null(statement, index)
            }
            guard result == SQLITE_OK else {
                throw SQLiteDatabaseError.bind(errorMessage)
            }
        }
    }

    private var errorMessage: String {
        handle.map { String(cString: sqlite3_errmsg($0)) } ?? "Unknown SQLite error"
    }
}
