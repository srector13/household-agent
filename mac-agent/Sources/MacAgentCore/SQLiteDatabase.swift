import Foundation
#if canImport(SQLite3)
import SQLite3
#elseif canImport(CSQLite)
import CSQLite
#endif

public struct SQLiteError: Error, CustomStringConvertible {
    public let code: Int32
    public let message: String
    public var description: String { "sqlite error \(code): \(message)" }
}

/// Thin wrapper over the SQLite C API — just enough for read-only queries against chat.db
/// (plus writes, used by tests to build fixture databases).
public final class SQLiteDatabase {
    private var db: OpaquePointer?

    /// Opens `path`. With `readOnly`, uses a `file:` URI with `mode=ro` so the Messages database is
    /// never modified or locked for writing; WAL changes remain visible to each new read transaction.
    public init(path: String, readOnly: Bool) throws {
        var flags: Int32
        let target: String
        if readOnly {
            let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
            target = "file:\(encoded)?mode=ro"
            flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI
        } else {
            target = path
            flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        }
        flags |= SQLITE_OPEN_NOMUTEX
        var handle: OpaquePointer?
        let rc = sqlite3_open_v2(target, &handle, flags, nil)
        if rc != SQLITE_OK {
            let msg = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(handle)
            throw SQLiteError(code: rc, message: msg)
        }
        db = handle
        sqlite3_busy_timeout(handle, 2000)
    }

    deinit {
        sqlite3_close(db)
    }

    private func error(_ rc: Int32) -> SQLiteError {
        SQLiteError(code: rc, message: db.map { String(cString: sqlite3_errmsg($0)) } ?? "closed")
    }

    public func execute(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &err)
        if rc != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "exec failed"
            sqlite3_free(err)
            throw SQLiteError(code: rc, message: msg)
        }
    }

    public enum Value {
        case int(Int64)
        case text(String)
        case blob(Data)
        case null
    }

    /// Runs `sql` with positional `params` and returns every row as an array of column values.
    public func query(_ sql: String, _ params: [Value] = []) throws -> [[Value]] {
        var stmt: OpaquePointer?
        var rc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK else { throw error(rc) }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, p) in params.enumerated() {
            let idx = Int32(i + 1)
            switch p {
            case .int(let v): rc = sqlite3_bind_int64(stmt, idx, v)
            case .text(let s): rc = sqlite3_bind_text(stmt, idx, s, -1, transient)
            case .blob(let d):
                rc = d.withUnsafeBytes { buf in
                    sqlite3_bind_blob(stmt, idx, buf.baseAddress, Int32(buf.count), transient)
                }
            case .null: rc = sqlite3_bind_null(stmt, idx)
            }
            guard rc == SQLITE_OK else { throw error(rc) }
        }
        var rows: [[Value]] = []
        let columns = sqlite3_column_count(stmt)
        while true {
            rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw error(rc) }
            var row: [Value] = []
            row.reserveCapacity(Int(columns))
            for c in 0..<columns {
                switch sqlite3_column_type(stmt, c) {
                case SQLITE_INTEGER:
                    row.append(.int(sqlite3_column_int64(stmt, c)))
                case SQLITE_FLOAT:
                    row.append(.int(Int64(sqlite3_column_double(stmt, c))))
                case SQLITE_TEXT:
                    row.append(.text(String(cString: sqlite3_column_text(stmt, c))))
                case SQLITE_BLOB:
                    let n = Int(sqlite3_column_bytes(stmt, c))
                    if n > 0, let p = sqlite3_column_blob(stmt, c) {
                        row.append(.blob(Data(bytes: p, count: n)))
                    } else {
                        row.append(.blob(Data()))
                    }
                default:
                    row.append(.null)
                }
            }
            rows.append(row)
        }
        return rows
    }
}

extension SQLiteDatabase.Value {
    var int: Int64? { if case .int(let v) = self { return v }; return nil }
    var string: String? {
        switch self {
        case .text(let s): return s
        case .int(let v): return String(v)
        default: return nil
        }
    }
    var data: Data? {
        switch self {
        case .blob(let d): return d
        case .text(let s): return Data(s.utf8)
        default: return nil
        }
    }
}
