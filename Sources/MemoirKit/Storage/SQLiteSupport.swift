import Foundation
import SQLite3

// MARK: - Destructor constants
//
// `SQLITE_TRANSIENT` and `SQLITE_STATIC` are C macros that cast an integer to a function
// pointer. Macros of that shape are not imported into Swift, so they are recreated here.
// `SQLITE_TRANSIENT` tells SQLite to take its own copy of the bytes we hand it, which is
// the only safe choice when binding a Swift `String`: the temporary C buffer Swift creates
// for the call is gone the moment `sqlite3_bind_text` returns.

/// The `SQLITE_TRANSIENT` destructor: instructs SQLite to copy the bound bytes immediately.
@inline(__always)
func sqliteTransient() -> sqlite3_destructor_type {
    let minusOne: Int = -1
    return unsafeBitCast(minusOne, to: sqlite3_destructor_type.self)
}

// MARK: - Errors

/// Builds a `MemoirError.storage` carrying the human-readable message from `sqlite3_errmsg`.
///
/// - Parameters:
///   - db: The connection the failure happened on. May be `nil` (e.g. a failed open).
///   - context: What we were trying to do, prepended to the SQLite message.
///   - code: Optional SQLite result code, appended for diagnosis.
func sqliteError(_ db: OpaquePointer?, _ context: String, code: Int32? = nil) -> MemoirError {
    var message = "unknown sqlite error"
    if let db, let raw = sqlite3_errmsg(db) {
        message = String(cString: raw)
    }
    // A full disk is the one storage failure a user can actually do something about, and
    // "database or disk is full (code 13)" is not the sentence that tells them so. It reached
    // every call site as an anonymous `.storage` and was swallowed by `try?` at most of them.
    if code == SQLITE_FULL || message.lowercased().contains("disk is full") {
        return .storage(
            "\(context): the disk is full. Free some space. Memoir cannot write until you do."
        )
    }
    if let code {
        return .storage("\(context): \(message) (code \(code))")
    }
    return .storage("\(context): \(message)")
}

/// Builds a `MemoirError.storage` from a raw result code when no connection is available.
func sqliteError(code: Int32, _ context: String) -> MemoirError {
    var message = "sqlite error \(code)"
    if let raw = sqlite3_errstr(code) {
        message = String(cString: raw)
    }
    return .storage("\(context): \(message) (code \(code))")
}

// MARK: - Binding
//
// All binders are 1-based, matching SQLite's parameter numbering. Every one of them checks
// the return code; a silent bind failure would write a NULL into a NOT NULL column and
// surface much later as a confusing constraint error.

/// Binds a non-null string parameter, copying the bytes (`SQLITE_TRANSIENT`).
func bindText(_ stmt: OpaquePointer, _ index: Int32, _ value: String) throws {
    let rc = sqlite3_bind_text(stmt, index, value, -1, sqliteTransient())
    guard rc == SQLITE_OK else {
        throw sqliteError(sqlite3_db_handle(stmt), "bind text at \(index)", code: rc)
    }
}

/// Binds a string parameter, writing SQL `NULL` when the value is `nil`.
func bindOptionalText(_ stmt: OpaquePointer, _ index: Int32, _ value: String?) throws {
    guard let value else {
        let rc = sqlite3_bind_null(stmt, index)
        guard rc == SQLITE_OK else {
            throw sqliteError(sqlite3_db_handle(stmt), "bind null at \(index)", code: rc)
        }
        return
    }
    try bindText(stmt, index, value)
}

/// Binds a floating point parameter.
func bindDouble(_ stmt: OpaquePointer, _ index: Int32, _ value: Double) throws {
    let rc = sqlite3_bind_double(stmt, index, value)
    guard rc == SQLITE_OK else {
        throw sqliteError(sqlite3_db_handle(stmt), "bind double at \(index)", code: rc)
    }
}

/// Binds an integer parameter (stored as INTEGER).
func bindInt(_ stmt: OpaquePointer, _ index: Int32, _ value: Int) throws {
    let rc = sqlite3_bind_int64(stmt, index, Int64(value))
    guard rc == SQLITE_OK else {
        throw sqliteError(sqlite3_db_handle(stmt), "bind int at \(index)", code: rc)
    }
}

/// Binds a boolean as 0 or 1.
func bindBool(_ stmt: OpaquePointer, _ index: Int32, _ value: Bool) throws {
    try bindInt(stmt, index, value ? 1 : 0)
}

/// Binds a `Date` as a REAL unix timestamp, the single date representation used everywhere
/// in this database.
func bindDate(_ stmt: OpaquePointer, _ index: Int32, _ value: Date) throws {
    try bindDouble(stmt, index, value.timeIntervalSince1970)
}

/// Binds an optional `Date` as a REAL unix timestamp, or SQL `NULL`.
func bindOptionalDate(_ stmt: OpaquePointer, _ index: Int32, _ value: Date?) throws {
    guard let value else {
        let rc = sqlite3_bind_null(stmt, index)
        guard rc == SQLITE_OK else {
            throw sqliteError(sqlite3_db_handle(stmt), "bind null at \(index)", code: rc)
        }
        return
    }
    try bindDouble(stmt, index, value.timeIntervalSince1970)
}

// MARK: - Column reading
//
// All readers are 0-based, matching SQLite's column numbering. Text is decoded from the
// UTF-8 buffer SQLite owns; the copy happens before the statement is stepped or finalized,
// so the pointer is always valid at the point of use.

/// Reads a text column, returning an empty string when the column is NULL.
func columnText(_ stmt: OpaquePointer, _ index: Int32) -> String {
    guard let raw = sqlite3_column_text(stmt, index) else { return "" }
    return String(decodingCString: raw, as: UTF8.self)
}

/// Reads a text column, returning `nil` when the column is NULL.
func columnOptionalText(_ stmt: OpaquePointer, _ index: Int32) -> String? {
    guard sqlite3_column_type(stmt, index) != SQLITE_NULL else { return nil }
    guard let raw = sqlite3_column_text(stmt, index) else { return nil }
    return String(decodingCString: raw, as: UTF8.self)
}

/// Reads a REAL column, returning 0 when NULL.
func columnDouble(_ stmt: OpaquePointer, _ index: Int32) -> Double {
    sqlite3_column_double(stmt, index)
}

/// Reads a REAL column, returning `nil` when NULL.
func columnOptionalDouble(_ stmt: OpaquePointer, _ index: Int32) -> Double? {
    guard sqlite3_column_type(stmt, index) != SQLITE_NULL else { return nil }
    return sqlite3_column_double(stmt, index)
}

/// Reads an INTEGER column as `Int`.
func columnInt(_ stmt: OpaquePointer, _ index: Int32) -> Int {
    Int(sqlite3_column_int64(stmt, index))
}

/// Reads an INTEGER column as `Bool` (anything non-zero is true).
func columnBool(_ stmt: OpaquePointer, _ index: Int32) -> Bool {
    sqlite3_column_int64(stmt, index) != 0
}

/// Reads a REAL unix timestamp column as a `Date`.
func columnDate(_ stmt: OpaquePointer, _ index: Int32) -> Date {
    Date(timeIntervalSince1970: sqlite3_column_double(stmt, index))
}

/// Reads a REAL unix timestamp column as a `Date`, returning `nil` when NULL.
func columnOptionalDate(_ stmt: OpaquePointer, _ index: Int32) -> Date? {
    guard let value = columnOptionalDouble(stmt, index) else { return nil }
    return Date(timeIntervalSince1970: value)
}

// MARK: - Statement execution
//
// These are free functions taking the connection explicitly rather than methods on `Store`,
// so that they can be used both from the actor's isolated methods and from the `nonisolated`
// connection-setup path that runs during `init`, before `self` is usable.

/// Prepares `sql`, hands the statement to `body`, and finalizes it on every exit path
/// including a thrown error. This is the only place statement lifetime is managed.
@discardableResult
func sqlWithStatement<T>(
    _ db: OpaquePointer,
    _ sql: String,
    _ body: (OpaquePointer) throws -> T
) throws -> T {
    var stmt: OpaquePointer?
    let rc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
    guard rc == SQLITE_OK, let stmt else {
        if let stmt { sqlite3_finalize(stmt) }
        throw sqliteError(db, "prepare: \(sqlOneLine(sql))", code: rc)
    }
    defer { sqlite3_finalize(stmt) }
    return try body(stmt)
}

/// Steps a statement that is expected to produce no rows.
func sqlStep(_ stmt: OpaquePointer, sql: String) throws {
    let rc = sqlite3_step(stmt)
    guard rc == SQLITE_DONE || rc == SQLITE_ROW else {
        throw sqliteError(sqlite3_db_handle(stmt), "step: \(sqlOneLine(sql))", code: rc)
    }
}

/// Steps a statement to exhaustion, decoding every row.
func sqlCollect<T>(
    _ stmt: OpaquePointer,
    sql: String,
    decode: (OpaquePointer) -> T
) throws -> [T] {
    var rows: [T] = []
    while true {
        let rc = sqlite3_step(stmt)
        switch rc {
        case SQLITE_ROW:
            rows.append(decode(stmt))
        case SQLITE_DONE:
            return rows
        default:
            throw sqliteError(sqlite3_db_handle(stmt), "step: \(sqlOneLine(sql))", code: rc)
        }
    }
}

/// Steps a statement expected to yield exactly one row and decodes it.
func sqlOneRow<T>(
    _ db: OpaquePointer,
    _ sql: String,
    bind: (OpaquePointer) throws -> Void = { _ in },
    decode: (OpaquePointer) -> T
) throws -> T? {
    try sqlWithStatement(db, sql) { stmt in
        try bind(stmt)
        let rc = sqlite3_step(stmt)
        switch rc {
        case SQLITE_ROW: return decode(stmt)
        case SQLITE_DONE: return nil
        default:
            throw sqliteError(db, "step: \(sqlOneLine(sql))", code: rc)
        }
    }
}

/// Executes a script of one or more statements, surfacing SQLite's own error text.
func sqlExec(_ db: OpaquePointer, _ sql: String) throws {
    var raw: UnsafeMutablePointer<CChar>?
    let rc = sqlite3_exec(db, sql, nil, nil, &raw)
    guard rc == SQLITE_OK else {
        var message = "unknown sqlite error"
        if let raw {
            message = String(cString: raw)
            sqlite3_free(raw)
        }
        throw MemoirError.storage("exec: \(sqlOneLine(sql)): \(message) (code \(rc))")
    }
    if let raw { sqlite3_free(raw) }
}

/// Collapses a multi-line SQL string so log lines and error messages stay on one line.
func sqlOneLine(_ sql: String) -> String {
    sql.split(whereSeparator: \.isNewline)
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .joined(separator: " ")
}

// MARK: - Query text helpers

enum SQLiteQueryText {
    /// Turns arbitrary user input into a safe FTS5 MATCH expression.
    ///
    /// FTS5 has its own query grammar: bare input containing `"`, `*`, `:`, `-`, `NEAR`,
    /// `AND`, or an unbalanced quote either throws a syntax error or silently means
    /// something the user did not intend. So we do not pass user text through: we split it
    /// into alphanumeric tokens and rebuild a phrase-quoted AND query, giving the final
    /// token a prefix wildcard so incremental typing matches.
    ///
    /// - Returns: A MATCH expression, or `nil` when the input has no usable tokens.
    static func ftsMatchExpression(for raw: String, maxTokens: Int = 16) -> String? {
        let tokens = raw
            .split(whereSeparator: { !($0.isLetter || $0.isNumber) })
            .prefix(maxTokens)
            .map { String($0) }
        guard !tokens.isEmpty else { return nil }

        // Drop the words that carry no signal. "what was that tweet about X" is mostly
        // scaffolding, and requiring it to appear verbatim is what made real questions
        // return nothing.
        let meaningful = tokens.filter { !stopWords.contains($0.lowercased()) }
        let effective = meaningful.isEmpty ? tokens : meaningful

        var parts: [String] = []
        parts.reserveCapacity(effective.count)
        for (offset, token) in effective.enumerated() {
            // Tokens contain only letters and digits by construction, so quoting is safe;
            // the doubling is belt-and-braces in case the tokenizer rule ever loosens.
            let escaped = token.replacingOccurrences(of: "\"", with: "\"\"")
            let isLast = offset == effective.count - 1
            parts.append(isLast ? "\"\(escaped)\"*" : "\"\(escaped)\"")
        }

        // OR, not implicit AND.
        //
        // FTS5 treats a space as AND, so every term had to appear: asked "what was that
        // tweet about claude skills wrapped in an sms app", the post said "wrapped INTO a
        // nice sms app LAYER" and the query matched nothing at all. With OR, BM25 ranks by
        // how many terms hit and how rare they are, and the same question puts that tweet
        // at rank #1. Partial matches are exactly what recall is made of.
        return parts.joined(separator: " OR ")
    }

    /// Words too common to narrow anything, and common enough to wreck an AND query.
    static let stopWords: Set<String> = [
        "a", "an", "the", "that", "this", "these", "those", "what", "which", "who",
        "was", "were", "is", "are", "am", "be", "been", "being", "did", "do", "does",
        "i", "me", "my", "mine", "you", "your", "it", "its", "we", "our",
        "about", "on", "in", "at", "of", "for", "to", "from", "with", "by",
        "and", "or", "but", "if", "then", "than", "so", "as",
        "have", "has", "had", "can", "could", "would", "should", "will",
        "last", "any", "some", "there", "here", "when", "where", "how", "why",
    ]

    /// Builds a `LIKE` pattern for the substring fallback used when FTS5 is unavailable.
    /// Escapes the LIKE metacharacters with a backslash; the SQL must use `ESCAPE '\'`.
    static func likePattern(for raw: String) -> String {
        var escaped = ""
        escaped.reserveCapacity(raw.count + 4)
        for character in raw {
            switch character {
            case "\\", "%", "_": escaped.append("\\"); escaped.append(character)
            default: escaped.append(character)
            }
        }
        return "%\(escaped)%"
    }
}


/// Binds a blob parameter, copying the bytes (`SQLITE_TRANSIENT`).
func bindBlob(_ stmt: OpaquePointer, _ index: Int32, _ data: Data) throws {
    let status = data.withUnsafeBytes { raw -> Int32 in
        // An empty blob still has to bind as a blob, not as NULL: empty means "attempted
        // and not embeddable", which is different from "not yet attempted".
        guard let base = raw.baseAddress, !raw.isEmpty else {
            return sqlite3_bind_zeroblob(stmt, index, 0)
        }
        return sqlite3_bind_blob(stmt, index, base, Int32(raw.count), sqliteTransient())
    }
    guard status == SQLITE_OK else {
        throw MemoirError.storage("bind blob at \(index) failed with status \(status)")
    }
}

/// Reads a blob column as raw bytes. Empty when the column is NULL or zero-length.
func columnBlob(_ stmt: OpaquePointer, _ index: Int32) -> Data {
    let count = Int(sqlite3_column_bytes(stmt, index))
    guard count > 0, let raw = sqlite3_column_blob(stmt, index) else { return Data() }
    return Data(bytes: raw, count: count)
}
