import Foundation
import SQLite3

/// A value read from, or bound into, a SQLite statement.
public enum SQLValue: Sendable, Equatable {
    case null
    case int(Int64)
    case double(Double)
    case text(String)
    case blob(Data)

    /// The text payload, converting numbers when needed.
    public var textValue: String? {
        switch self {
        case .text(let s): return s
        case .int(let i): return String(i)
        case .double(let d): return String(d)
        case .blob, .null: return nil
        }
    }

    /// The integer payload, converting text/doubles when they look numeric.
    public var intValue: Int64? {
        switch self {
        case .int(let i): return i
        case .double(let d) where d.isFinite: return Int64(d)
        case .text(let s): return Int64(s)
        default: return nil
        }
    }

    /// The floating point payload.
    public var doubleValue: Double? {
        switch self {
        case .int(let i): return Double(i)
        case .double(let d): return d
        case .text(let s): return Double(s)
        default: return nil
        }
    }

    /// A boolean reading: non-zero numbers and the usual truthy strings.
    public var boolValue: Bool? {
        switch self {
        case .int(let i): return i != 0
        case .double(let d): return d != 0
        case .text(let s):
            switch s.lowercased() {
            case "1", "true", "yes", "y", "t": return true
            case "0", "false", "no", "n", "f": return false
            default: return nil
            }
        default: return nil
        }
    }

    /// True when the value is SQL NULL.
    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }
}

/// One result row, addressed by column name.
public struct SQLRow: Sendable {
    private let values: [String: SQLValue]

    public init(_ values: [String: SQLValue]) { self.values = values }

    /// Looks a column up by name. Missing columns read as `.null`.
    public subscript(column: String) -> SQLValue {
        values[column] ?? .null
    }

    /// All column names present in the row.
    public var columns: [String] { Array(values.keys) }
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// A strictly read-only SQLite connection.
///
/// The handle is opened with `SQLITE_OPEN_READONLY` and `PRAGMA query_only=ON`,
/// so a bug in a higher layer still cannot write to the user's memory database.
/// The type is a class (not `Sendable`); it is always owned by an actor.
final class SQLiteReadOnly {
    /// The outcome of trying to open the database file.
    enum OpenResult: Sendable, Equatable {
        /// The file was opened and answers queries.
        case opened
        /// No file exists at the given path yet.
        case missing
        /// The file exists but could not be opened or read.
        case failed(String)
    }

    /// Absolute filesystem path of the database.
    let path: String

    private var db: OpaquePointer?

    /// The most recent SQLite error message, for diagnostics on stderr.
    private(set) var lastError: String?

    init(path: String) {
        self.path = path
    }

    deinit {
        if let db { sqlite3_close_v2(db) }
    }

    /// True once a usable connection is held.
    var isOpen: Bool { db != nil }

    /// Opens the database read-only.
    ///
    /// If a plain read-only open cannot read the file (typically a stale
    /// write-ahead log whose shared-memory index cannot be created), the
    /// connection is retried in `immutable` mode, which never touches the WAL.
    func open() -> OpenResult {
        if db != nil { return .opened }
        guard FileManager.default.fileExists(atPath: path) else { return .missing }

        var handle: OpaquePointer?
        let rc = sqlite3_open_v2(path, &handle, SQLITE_OPEN_READONLY, nil)
        if rc == SQLITE_OK, let handle {
            db = handle
            configure()
            if smokeTest() { return .opened }
            // Readable file, unreadable content: fall through to immutable mode.
            sqlite3_close_v2(handle)
            db = nil
        } else {
            if let handle {
                lastError = String(cString: sqlite3_errmsg(handle))
                sqlite3_close_v2(handle)
            } else {
                lastError = "sqlite3_open_v2 returned \(rc)"
            }
        }

        var immutableHandle: OpaquePointer?
        let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        let uri = "file:\(encoded)?mode=ro&immutable=1"
        let rc2 = sqlite3_open_v2(uri, &immutableHandle, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil)
        if rc2 == SQLITE_OK, let immutableHandle {
            db = immutableHandle
            configure()
            if smokeTest() {
                MCPLog.warn("opened \(path) in immutable read-only mode; very recent writes may be invisible")
                return .opened
            }
            sqlite3_close_v2(immutableHandle)
            db = nil
        } else if let immutableHandle {
            lastError = String(cString: sqlite3_errmsg(immutableHandle))
            sqlite3_close_v2(immutableHandle)
        }

        return .failed(lastError ?? "unknown SQLite error")
    }

    private func configure() {
        guard let db else { return }
        sqlite3_busy_timeout(db, 2_000)
        // Belt and braces: refuse writes at the connection level too.
        _ = execute("PRAGMA query_only = ON;")
    }

    private func smokeTest() -> Bool {
        !query("SELECT count(*) AS n FROM sqlite_master", []).isEmpty
    }

    /// Runs a statement that returns no rows (only used for PRAGMAs).
    @discardableResult
    private func execute(_ sql: String) -> Bool {
        guard let db else { return false }
        var errorPointer: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &errorPointer)
        if let errorPointer {
            lastError = String(cString: errorPointer)
            sqlite3_free(errorPointer)
        }
        return rc == SQLITE_OK
    }

    /// Runs a query and materialises every row.
    ///
    /// Errors are recorded in `lastError` and surface as an empty result, so a
    /// malformed or schema-mismatched query degrades to "no data" instead of
    /// crashing the server.
    func query(_ sql: String, _ binds: [SQLValue] = []) -> [SQLRow] {
        guard let db else {
            lastError = "database is not open"
            return []
        }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            lastError = String(cString: sqlite3_errmsg(db))
            MCPLog.debug("prepare failed: \(lastError ?? "?") for SQL: \(sql)")
            return []
        }
        defer { sqlite3_finalize(statement) }

        for (offset, value) in binds.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case .null:
                sqlite3_bind_null(statement, index)
            case .int(let v):
                sqlite3_bind_int64(statement, index, v)
            case .double(let v):
                sqlite3_bind_double(statement, index, v)
            case .text(let v):
                sqlite3_bind_text(statement, index, v, -1, sqliteTransient)
            case .blob(let data):
                _ = data.withUnsafeBytes { raw in
                    sqlite3_bind_blob(statement, index, raw.baseAddress, Int32(data.count), sqliteTransient)
                }
            }
        }

        var rows: [SQLRow] = []
        let columnCount = sqlite3_column_count(statement)
        var names: [String] = []
        names.reserveCapacity(Int(columnCount))
        for i in 0..<columnCount {
            names.append(sqlite3_column_name(statement, i).map { String(cString: $0) } ?? "col\(i)")
        }

        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_ROW {
                var values: [String: SQLValue] = [:]
                values.reserveCapacity(names.count)
                for i in 0..<columnCount {
                    values[names[Int(i)]] = SQLiteReadOnly.value(statement, i)
                }
                rows.append(SQLRow(values))
            } else if step == SQLITE_DONE {
                break
            } else {
                lastError = String(cString: sqlite3_errmsg(db))
                MCPLog.debug("step failed: \(lastError ?? "?")")
                break
            }
        }
        return rows
    }

    private static func value(_ statement: OpaquePointer, _ index: Int32) -> SQLValue {
        switch sqlite3_column_type(statement, index) {
        case SQLITE_INTEGER:
            return .int(sqlite3_column_int64(statement, index))
        case SQLITE_FLOAT:
            return .double(sqlite3_column_double(statement, index))
        case SQLITE_TEXT:
            if let cString = sqlite3_column_text(statement, index) {
                return .text(String(cString: cString))
            }
            return .null
        case SQLITE_BLOB:
            let count = Int(sqlite3_column_bytes(statement, index))
            if count > 0, let bytes = sqlite3_column_blob(statement, index) {
                return .blob(Data(bytes: bytes, count: count))
            }
            return .blob(Data())
        default:
            return .null
        }
    }

    /// Table name -> ordered column names, for every table and view in the file.
    func introspectSchema() -> [String: [String]] {
        var schema: [String: [String]] = [:]
        let tables = query(
            "SELECT name FROM sqlite_master WHERE type IN ('table','view') AND name NOT LIKE 'sqlite_%'"
        )
        for row in tables {
            guard let name = row["name"].textValue, SQLiteReadOnly.isSafeIdentifier(name) else { continue }
            let columns = query("PRAGMA table_info(\"\(name)\")")
                .compactMap { $0["name"].textValue }
                .filter(SQLiteReadOnly.isSafeIdentifier)
            if !columns.isEmpty { schema[name] = columns }
        }
        return schema
    }

    /// Identifiers taken from the schema are still validated before being
    /// interpolated into SQL. Nothing user-supplied ever reaches this path.
    static func isSafeIdentifier(_ s: String) -> Bool {
        !s.isEmpty && s.count <= 64 && s.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }
}
