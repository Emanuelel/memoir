import Foundation
import SQLite3

/// Owns one `sqlite3 *` handle and guarantees it is closed exactly once.
///
/// The handle lives in a class rather than directly in the actor so that ownership is tied
/// to ARC: when the `Store` goes away the box goes away and `sqlite3_close_v2` runs, with no
/// need for an actor `deinit` to reach into isolated state.
///
/// Not `Sendable` on purpose: it is only ever reachable through `Store`'s isolation.
private final class SQLiteConnection {
    let db: OpaquePointer
    private var isClosed = false

    init(db: OpaquePointer) {
        self.db = db
    }

    /// Closes the handle. Idempotent.
    func close() {
        guard !isClosed else { return }
        isClosed = true
        sqlite3_close_v2(db)
    }

    deinit {
        close()
    }
}

/// Memoir's entire persistent memory: captures, entities, provenance and sessions, in one
/// SQLite file driven through the raw C API.
///
/// `Store` is an `actor`, so the connection handle and every prepared statement are confined
/// to a single execution context. That is deliberate: sharing a SQLite connection across
/// threads is a whole category of bug, and serialising at the actor removes it. Callers
/// `await` every method.
///
/// Conventions used throughout the schema:
/// - Dates are stored as REAL unix timestamps (`Date.timeIntervalSince1970`).
/// - Booleans are INTEGER `0` / `1`.
/// - IDs are lowercase UUID strings, matching `ID` in `CoreTypes`.
/// - Retention is two-tier: captures roll off (``purgeCaptures(olderThan:)``), entities
///   persist forever and are only ever *soft* deleted.
///
/// Failure policy: every SQLite return code is checked and every failure is thrown as
/// ``MemoirError/storage(_:)`` carrying the `sqlite3_errmsg` text. Nothing is swallowed.
public actor Store {

    // MARK: - Stored state

    /// The open connection, or `nil` after ``close()``.
    private var connection: SQLiteConnection?

    /// True when the FTS5 tables exist and may be used. False only on a SQLite build without
    /// FTS5, where search degrades to a `LIKE` scan instead of the store failing to open.
    private let hasFullTextSearch: Bool

    /// The file this store is backed by.
    public nonisolated let databaseURL: URL

    /// True when the connection was opened `SQLITE_OPEN_READONLY`. Every mutating method
    /// throws immediately on such a store.
    public nonisolated let isReadOnly: Bool

    // MARK: - Lifecycle

    /// Opens (creating if needed) the database at `path` for reading and writing, applies any
    /// outstanding migrations, and ensures the full-text indexes exist.
    ///
    /// Enables WAL journalling, `PRAGMA foreign_keys = ON` and a 5 second busy timeout.
    ///
    /// - Parameter path: File URL of the SQLite database. Parent directories are created.
    /// - Throws: ``MemoirError/storage(_:)`` if the file cannot be opened or migrated.
    /// - Parameter mayMigrate: pass `true` only from the app, which can tell the user what
    ///   is about to happen. Tools leave it `false` and get a clear error instead of quietly
    ///   upgrading a database another build still has to open.
    public init(path: URL, mayMigrate: Bool = false) throws {
        self.databaseURL = path
        self.isReadOnly = false

        let directory = path.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let db = try Store.openHandle(
            at: path,
            flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        )
        do {
            try Store.configure(db, writable: true)
            try Store.migrate(db, consented: mayMigrate)
            self.hasFullTextSearch = Store.installFullTextSearch(db)
        } catch {
            sqlite3_close_v2(db)
            throw error
        }
        self.connection = SQLiteConnection(db: db)

        Log.shared.info("store opened rw at \(path.path) (fts: \(hasFullTextSearch))")
    }

    /// Opens an **existing** database strictly read-only (`SQLITE_OPEN_READONLY`).
    ///
    /// This is the variant the MCP server uses: it cannot write, cannot migrate and cannot
    /// create the file. A missing or un-initialised database throws rather than silently
    /// presenting an empty memory.
    ///
    /// - Parameter readOnlyPath: File URL of an existing Memoir database.
    /// - Throws: ``MemoirError/storage(_:)`` if the file is missing, unreadable, or carries no
    ///   Memoir schema.
    public init(readOnlyPath: URL) throws {
        self.databaseURL = readOnlyPath
        self.isReadOnly = true

        guard FileManager.default.fileExists(atPath: readOnlyPath.path) else {
            throw MemoirError.storage("no database at \(readOnlyPath.path)")
        }

        let db = try Store.openHandle(
            at: readOnlyPath,
            flags: SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        )
        do {
            try Store.configure(db, writable: false)
            let version = try Store.userVersion(db)
            guard version >= 1 else {
                throw MemoirError.storage(
                    "database at \(readOnlyPath.path) has no Memoir schema yet (user_version 0)"
                )
            }
            if version > Schema.version {
                // Newer is not broken. A version check that bricks a working app turns a
                // partial rollout - old app, new tool, or a downgrade - into "Memoir can't
                // start" over a database that is perfectly intact. Read what we understand
                // and say so; every column this build knows is still there, because
                // migrations are additive by rule.
                Log.shared.warn(
                    "database is v\(version), newer than this build (v\(Schema.version)). "
                    + "Reading it anyway; update Memoir to use everything in it."
                )
            }
            self.hasFullTextSearch = try Store.detectFullTextSearch(db)
        } catch {
            sqlite3_close_v2(db)
            throw error
        }
        self.connection = SQLiteConnection(db: db)

        Log.shared.info("store opened ro at \(readOnlyPath.path) (fts: \(hasFullTextSearch))")
    }

    /// Convenience factory for the read-only variant, for the MCP server.
    ///
    /// - Parameter path: File URL of an existing Memoir database. Defaults to ``defaultPath()``.
    public static func openReadOnly(path: URL = Store.defaultPath()) throws -> Store {
        try Store(readOnlyPath: path)
    }

    /// The standard database location: `~/Library/Application Support/Memoir/memoir.sqlite`.
    public static func defaultPath() -> URL {
        Paths.databaseURL()
    }

    /// Closes the connection. Subsequent calls throw ``MemoirError/storage(_:)``. Idempotent.
    ///
    /// Not usually necessary (the handle closes when the store is deallocated) but tests
    /// and the MCP server benefit from a deterministic close.
    public func close() {
        guard let connection else { return }
        if !isReadOnly {
            // Fold the WAL back into the main file so a copied .sqlite is complete.
            _ = sqlite3_exec(connection.db, "PRAGMA wal_checkpoint(TRUNCATE);", nil, nil, nil)
        }
        connection.close()
        self.connection = nil
    }

    // MARK: - Captures

    /// Inserts a capture, replacing any existing row with the same id.
    ///
    /// The replace path fires the FTS delete + insert triggers, so the full-text index stays
    /// correct even for a re-inserted id.
    public func insert(capture: CaptureEvent) throws {
        try ensureWritable()
        let sql = """
        INSERT OR REPLACE INTO captures (\(Schema.captureColumns))
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        """
        try withStatement(sql) { stmt in
            try bindText(stmt, 1, capture.id)
            try bindDate(stmt, 2, capture.ts)
            try bindText(stmt, 3, capture.appBundleID)
            try bindText(stmt, 4, capture.appName)
            try bindOptionalText(stmt, 5, capture.windowTitle)
            try bindText(stmt, 6, capture.text)
            try bindText(stmt, 7, capture.textHash)
            try bindOptionalText(stmt, 8, capture.visibleText)
            try bindOptionalText(stmt, 9, capture.localDay)
            try sqlStep(stmt, sql: sql)
        }
    }

    /// Captures recorded at or after `since`, newest first.
    ///
    /// - Parameters:
    ///   - since: Inclusive lower bound on the capture timestamp.
    ///   - limit: Maximum rows. Zero or negative means no limit.
    public func captures(since: Date, limit: Int) throws -> [CaptureEvent] {
        let sql = """
        SELECT \(Schema.captureColumns) FROM captures
        WHERE ts >= ?
        ORDER BY ts DESC
        LIMIT ?
        """
        return try withStatement(sql) { stmt in
            try bindDate(stmt, 1, since)
            try bindInt(stmt, 2, Store.sqlLimit(limit))
            return try sqlCollect(stmt, sql: sql, decode: Store.decodeCapture)
        }
    }

    /// Captures inside a closed range, newest first.
    ///
    /// The upper bound lives in the SQL, where it must be. The old pattern,
    /// `captures(since: windowStart, limit: N)` then filtering `ts <= windowEnd` in
    /// Swift, let the newest rows consume the LIMIT quota first: by 17:00 of a busy
    /// day, a question about *yesterday* fetched 200 rows of today, filtered all of
    /// them away, and reported yesterday as empty while hundreds of its captures sat
    /// on disk. A limit must apply to the window that was asked about.
    public func captures(from: Date, to: Date, limit: Int) throws -> [CaptureEvent] {
        let sql = """
        SELECT \(Schema.captureColumns) FROM captures
        WHERE ts >= ? AND ts <= ?
        ORDER BY ts DESC
        LIMIT ?
        """
        return try withStatement(sql) { stmt in
            try bindDate(stmt, 1, from)
            try bindDate(stmt, 2, to)
            try bindInt(stmt, 3, Store.sqlLimit(limit))
            return try sqlCollect(stmt, sql: sql, decode: Store.decodeCapture)
        }
    }

    /// Captures inside a closed range from named apps only, newest first.
    ///
    /// The filter belongs in the SQL for the same reason the upper bound above does, and
    /// the failure here is worse. The imported sources are timestamped by *when the thing
    /// happened*, so a photo day row sits at 00:00 and a morning meeting at 09:00, the
    /// oldest rows of the day. Fetching the whole day with a limit and filtering in Swift
    /// therefore spends the entire quota on screen captures from the last hour and drops
    /// exactly the rows the caller came for, on precisely the busy days when the day is
    /// worth writing about.
    public func captures(
        from: Date, to: Date, appBundleIDs: [String], limit: Int
    ) throws -> [CaptureEvent] {
        guard !appBundleIDs.isEmpty else { return [] }
        let placeholders = appBundleIDs.map { _ in "?" }.joined(separator: ", ")
        let sql = """
        SELECT \(Schema.captureColumns) FROM captures
        WHERE ts >= ? AND ts <= ? AND app_bundle_id IN (\(placeholders))
        ORDER BY ts DESC
        LIMIT ?
        """
        return try withStatement(sql) { stmt in
            try bindDate(stmt, 1, from)
            try bindDate(stmt, 2, to)
            for (offset, bundleID) in appBundleIDs.enumerated() {
                try bindText(stmt, Int32(3 + offset), bundleID)
            }
            try bindInt(stmt, Int32(3 + appBundleIDs.count), Store.sqlLimit(limit))
            return try sqlCollect(stmt, sql: sql, decode: Store.decodeCapture)
        }
    }

    /// A single capture by id, or `nil` when it is gone, most likely rolled off by
    /// retention, which is normal and not an error.
    public func capture(id: ID) throws -> CaptureEvent? {
        let sql = "SELECT \(Schema.captureColumns) FROM captures WHERE id = ? LIMIT 1"
        return try withStatement(sql) { stmt in
            try bindText(stmt, 1, id)
            return try sqlCollect(stmt, sql: sql, decode: Store.decodeCapture).first
        }
    }

    /// Full-text search over capture text, newest first.
    ///
    /// The query is user input and is never handed to FTS5 verbatim: it is tokenised and
    /// rebuilt as a quoted AND expression with a trailing prefix wildcard, so no input can be
    /// a syntax error or an accidental operator. Falls back to a `LIKE` substring scan on a
    /// SQLite build without FTS5.
    ///
    /// - Parameters:
    ///   - query: Raw user text.
    ///   - limit: Maximum rows. Zero or negative means no limit.
    public func searchCaptures(_ query: String, limit: Int) throws -> [CaptureEvent] {
        let bounded = Store.sqlLimit(limit)

        guard hasFullTextSearch, let match = SQLiteQueryText.ftsMatchExpression(for: query) else {
            guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
            let sql = """
            SELECT \(Schema.captureColumns) FROM captures
            WHERE text LIKE ? ESCAPE '\\'
            ORDER BY ts DESC
            LIMIT ?
            """
            return try withStatement(sql) { stmt in
                try bindText(stmt, 1, SQLiteQueryText.likePattern(for: query))
                try bindInt(stmt, 2, bounded)
                return try sqlCollect(stmt, sql: sql, decode: Store.decodeCapture)
            }
        }

        // Relevance order must survive to the caller.
        //
        // The inner query ranked by BM25 and the outer one then re-sorted by `ts DESC`,
        // throwing that ranking away, so the most RECENT match won rather than the best
        // one. A search for a specific tweet returned whatever page happened to be newest
        // and contain any single word of the question. Join against the FTS table instead
        // and keep its ordering.
        let sql = """
        SELECT \(Schema.captureColumns.split(separator: ",")
                    .map { "captures.\($0.trimmingCharacters(in: .whitespaces))" }
                    .joined(separator: ", ")) FROM captures
        JOIN captures_fts ON captures_fts.rowid = captures.rowid
        WHERE captures_fts MATCH ?
        ORDER BY captures_fts.rank
        LIMIT ?
        """
        return try withStatement(sql) { stmt in
            try bindText(stmt, 1, match)
            try bindInt(stmt, 2, bounded)
            return try sqlCollect(stmt, sql: sql, decode: Store.decodeCapture)
        }
    }

    /// Captures containing an exact adjacent phrase, best first.
    ///
    /// Ordinary search ORs the question's words, which is right for recall and blunt for
    /// precision. Asked for "the repo about **screen memory**", OR-search ranked mem0
    /// ("Universal memory layer for AI Agents") above Afterglance, because both contain
    /// "memory" and BM25 has no way to know the two words belonged together.
    ///
    /// Two words the asker put side by side are a much stronger signal than the same two
    /// words scattered across a page. FTS5 expresses that directly with a quoted phrase.
    public func searchCapturesPhrase(_ phrase: String, limit: Int) throws -> [CaptureEvent] {
        let words = phrase
            .split(whereSeparator: { !($0.isLetter || $0.isNumber) })
            .prefix(6)
            .map { $0.replacingOccurrences(of: "\"", with: "\"\"") }
        guard hasFullTextSearch, words.count >= 2 else { return [] }
        let match = "\"" + words.joined(separator: " ") + "\""
        let sql = """
        SELECT \(Schema.captureColumns.split(separator: ",")
                    .map { "captures.\($0.trimmingCharacters(in: .whitespaces))" }
                    .joined(separator: ", ")) FROM captures
        JOIN captures_fts ON captures_fts.rowid = captures.rowid
        WHERE captures_fts MATCH ?
        ORDER BY captures_fts.rank
        LIMIT ?
        """
        return try withStatement(sql) { stmt in
            try bindText(stmt, 1, match)
            try bindInt(stmt, 2, Store.sqlLimit(limit))
            return try sqlCollect(stmt, sql: sql, decode: Store.decodeCapture)
        }
    }

    // MARK: - Entities

    /// Inserts or updates an entity by id.
    ///
    /// `created_at` never moves forward: an update keeps the earlier of the stored and the
    /// supplied value. Everything else is written exactly as given. The "never overwrite a
    /// corrected entity" law lives in `MemoryService`, not here, because the user's own edit
    /// is itself an upsert and must be allowed to land.
    public func upsert(entity: Entity) throws {
        try ensureWritable()
        let sql = """
        INSERT INTO entities (\(Schema.entityColumns))
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            kind = excluded.kind,
            title = excluded.title,
            detail = excluded.detail,
            due_at = excluded.due_at,
            confidence = excluded.confidence,
            pinned = excluded.pinned,
            corrected = excluded.corrected,
            deleted = excluded.deleted,
            created_at = min(entities.created_at, excluded.created_at),
            updated_at = excluded.updated_at,
            -- Authored never decays to inferred. An extraction pass writing over an entity
            -- the user typed may update confidence and timestamps, but it can never demote
            -- the provenance of the claim itself. Enforced in SQL as well as in
            -- MemoryMerge, because the store is the last line and this one matters.
            source = CASE WHEN entities.source = 'authored' THEN 'authored' ELSE excluded.source END,
            completed_at = excluded.completed_at,
            aliases = excluded.aliases,
            provisional = excluded.provisional,
            -- Never cleared by a re-write. A journal entry filed under a day stays filed under
            -- it: the day it is about is the user's decision, not something a later pass knows
            -- better. COALESCE rather than assignment so an edit that forgets to carry the
            -- field cannot silently unfile somebody's diary.
            filed_at = COALESCE(excluded.filed_at, entities.filed_at)
        """
        try withStatement(sql) { stmt in
            try bindText(stmt, 1, entity.id)
            try bindText(stmt, 2, entity.kind.rawValue)
            try bindText(stmt, 3, entity.title)
            try bindOptionalText(stmt, 4, entity.detail)
            try bindOptionalDate(stmt, 5, entity.dueAt)
            try bindDouble(stmt, 6, entity.confidence)
            try bindBool(stmt, 7, entity.pinned)
            try bindBool(stmt, 8, entity.corrected)
            try bindBool(stmt, 9, entity.deleted)
            try bindDate(stmt, 10, entity.createdAt)
            try bindDate(stmt, 11, entity.updatedAt)
            try bindText(stmt, 12, entity.source.rawValue)
            try bindOptionalDate(stmt, 13, entity.completedAt)
            try bindText(stmt, 14, Store.encodeAliases(entity.aliases))
            try bindBool(stmt, 15, entity.provisional)
            try bindOptionalDate(stmt, 16, entity.filedAt)
            try sqlStep(stmt, sql: sql)
        }
    }

    /// Aliases as a stable JSON array string, `"[]"` when empty.
    ///
    /// Sorted-keys is irrelevant for an array, but the encoder is deliberately plain:
    /// this string round-trips through the `aliases` column and nothing else.
    static func encodeAliases(_ aliases: [String]) -> String {
        guard !aliases.isEmpty,
              let data = try? JSONEncoder().encode(aliases),
              let text = String(data: data, encoding: .utf8) else { return "[]" }
        return text
    }

    /// The inverse of ``encodeAliases(_:)``. Malformed data degrades to no aliases:
    /// a memory row must never fail to load over a decoration.
    static func decodeAliases(_ text: String) -> [String] {
        guard text != "[]", let data = text.data(using: .utf8),
              let list = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return list
    }

    /// Entities, optionally filtered by kind: pinned first, then most recently updated.
    ///
    /// - Parameters:
    ///   - kind: Restrict to one kind, or `nil` for every kind.
    ///   - includeDeleted: When false (the usual case) soft-deleted entities are hidden.
    public func entities(kind: EntityKind?, includeDeleted: Bool) throws -> [Entity] {
        var clauses: [String] = []
        // Both fragments are compile-time constants; the kind itself is a bound parameter.
        if kind != nil { clauses.append("kind = ?") }
        if !includeDeleted { clauses.append("deleted = 0") }

        var statement = "SELECT \(Schema.entityColumns) FROM entities"
        if !clauses.isEmpty { statement += " WHERE " + clauses.joined(separator: " AND ") }
        statement += " ORDER BY pinned DESC, updated_at DESC"
        let sql = statement

        return try withStatement(sql) { stmt in
            if let kind { try bindText(stmt, 1, kind.rawValue) }
            return try sqlCollect(stmt, sql: sql, decode: Store.decodeEntity)
        }
    }

    /// The notes of a day, split into the two things they actually are.
    ///
    /// `source == .authored` was doing this job and cannot: the vault importer marks every
    /// imported markdown file authored too, on purpose: it is your writing, and the merge law
    /// has to protect it from anything that guesses. So a day showing "everything authored"
    /// showed three Obsidian filenames beside the sentence somebody typed into the journal, at
    /// the same weight, with nothing to tell them apart.
    ///
    /// The distinction that does hold is provenance, and `MemoryService.commitPush` already
    /// states it: an entry written here "carries no provenance, deliberately: provenance points
    /// at the capture a claim was inferred from, and there is no capture here. The user is the
    /// source." Everything Memoir picked up, whether off a screen or out of a folder, points at
    /// the capture it came from. Nothing written in the journal points at anything.
    ///
    /// - Parameters:
    ///   - written: true for journal entries, false for everything else the day's notes hold.
    ///   - from: start of the range, inclusive.
    ///   - to: end of the range, exclusive.
    public func notes(written: Bool, from: Date, to: Date) throws -> [Entity] {
        let hasNoProvenance = "NOT EXISTS (SELECT 1 FROM provenance WHERE entity_id = entities.id)"
        let test = written
            ? "source = 'authored' AND \(hasNoProvenance)"
            : "NOT (source = 'authored' AND \(hasNoProvenance))"
        let sql = """
        SELECT \(Schema.entityColumns) FROM entities
        WHERE kind = 'note' AND deleted = 0
          AND updated_at >= ? AND updated_at < ?
          AND \(test)
        ORDER BY updated_at DESC
        """
        return try withStatement(sql) { stmt in
            try bindDate(stmt, 1, from)
            try bindDate(stmt, 2, to)
            return try sqlCollect(stmt, sql: sql, decode: Store.decodeEntity)
        }
    }

    /// The day-of-month numbers in `[from, to)` for which the record holds anything at all.
    ///
    /// The month grid's second signal. Its shading answers "how much did you write", which on
    /// most people's calendars is a nearly empty month, and a memory product whose calendar
    /// looks empty is arguing against itself, because the record is not empty at all. This says
    /// which days it has something for.
    ///
    /// Aggregated in SQL on purpose: `captures` is millions of rows and this runs on every
    /// month step. It must never become "load the month and count in Swift".
    ///
    /// - Important: day-of-month only, so the range must sit inside one month, which is what a
    ///   month grid always asks for.
    public func recordedDays(from: Date, to: Date) throws -> Set<Int> {
        let sql = """
        SELECT DISTINCT CAST(strftime('%d', ts, 'unixepoch', 'localtime') AS INTEGER)
        FROM captures WHERE ts >= ? AND ts < ?
        """
        return try withStatement(sql) { stmt in
            try bindDate(stmt, 1, from)
            try bindDate(stmt, 2, to)
            return Set(try sqlCollect(stmt, sql: sql) { columnInt($0, 0) })
        }
    }

    /// Rewrites what a journal entry says, in place.
    ///
    /// The only edit path there is, and it exists because every other write mints its id from
    /// the text: `MemoryService.pushID` hashes the normalised title, so saving an edit through
    /// the ordinary path lands a *second* entry and leaves the first one standing.
    ///
    /// `updated_at` is deliberately untouched. It is not "last modified" anywhere in this
    /// codebase — it is the day the entry is filed under, which the day view filters on, the
    /// month grid counts, and *on this day* groups by. Bumping it here would silently move
    /// Monday's entry into today and recount the month.
    ///
    /// Notes only. Nothing else in the store is a thing the user is allowed to rewrite by hand.
    public func rewriteNote(id: ID, title: String) throws {
        try ensureWritable()
        let sql = "UPDATE entities SET title = ? WHERE id = ? AND kind = 'note'"
        try withStatement(sql) { stmt in
            try bindText(stmt, 1, title)
            try bindText(stmt, 2, id)
            try sqlStep(stmt, sql: sql)
        }
    }

    /// A single entity by id, including soft-deleted ones, or `nil` if no such row exists.
    public func entity(id: ID) throws -> Entity? {
        let sql = "SELECT \(Schema.entityColumns) FROM entities WHERE id = ? LIMIT 1"
        return try withStatement(sql) { stmt in
            try bindText(stmt, 1, id)
            return try sqlCollect(stmt, sql: sql, decode: Store.decodeEntity).first
        }
    }

    /// Soft-deletes an entity: sets `deleted = 1` and bumps `updated_at`.
    ///
    /// The row, its provenance and its history stay on disk; only ``purgeEverything()``
    /// removes entity rows for real. A missing id is a no-op, not an error.
    ///
    /// - Parameters:
    ///   - id: The entity to retire.
    ///   - corrected: True when a person decided this, false when a sweep did.
    ///
    ///     Both used to write byte-identical rows, and the cost of that showed up the first
    ///     time anyone asked how often the user corrects their memory: `sum(corrected)` was 0
    ///     across every entity on a 75-day-old installation, and proving it meant comparing
    ///     migration backups by filename, because a human clicking "Not a person" left no
    ///     trace a consolidation sweep does not also leave. A memory that cannot tell its own
    ///     guesses from its owner's judgement cannot honour authored-beats-inferred, which is
    ///     the oldest rule in the product.
    ///
    ///     Passing false never *clears* the flag — a row corrected once stays corrected — so
    ///     a sweep can retire something the user already ruled on without overwriting the
    ///     ruling.
    public func deleteEntity(id: ID, corrected: Bool = false) throws {
        try ensureWritable()
        let sql = corrected
            ? "UPDATE entities SET deleted = 1, corrected = 1, updated_at = ? WHERE id = ?"
            : "UPDATE entities SET deleted = 1, updated_at = ? WHERE id = ?"
        try withStatement(sql) { stmt in
            try bindDate(stmt, 1, Date())
            try bindText(stmt, 2, id)
            try sqlStep(stmt, sql: sql)
        }
        if changes() == 0 {
            Log.shared.debug("deleteEntity: no entity with id \(id)")
        }
    }

    /// Full-text search over entity titles and details, excluding soft-deleted rows.
    ///
    /// Same query sanitising and `LIKE` fallback as ``searchCaptures(_:limit:)``.
    ///
    /// - Parameters:
    ///   - query: Raw user text.
    ///   - limit: Maximum rows. Zero or negative means no limit.
    public func searchEntities(_ query: String, limit: Int) throws -> [Entity] {
        let bounded = Store.sqlLimit(limit)
        // The FTS subquery cannot see `deleted`, so it over-fetches and the outer query
        // trims. Without this, a memory full of deleted rows would return short results.
        let innerLimit = bounded < 0 ? -1 : min(bounded * 4, 10_000)

        guard hasFullTextSearch, let match = SQLiteQueryText.ftsMatchExpression(for: query) else {
            guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
            let sql = """
            SELECT \(Schema.entityColumns) FROM entities
            WHERE deleted = 0
              AND (title LIKE ? ESCAPE '\\' OR IFNULL(detail, '') LIKE ? ESCAPE '\\')
            ORDER BY pinned DESC, updated_at DESC
            LIMIT ?
            """
            return try withStatement(sql) { stmt in
                let pattern = SQLiteQueryText.likePattern(for: query)
                try bindText(stmt, 1, pattern)
                try bindText(stmt, 2, pattern)
                try bindInt(stmt, 3, bounded)
                return try sqlCollect(stmt, sql: sql, decode: Store.decodeEntity)
            }
        }

        let sql = """
        SELECT \(Schema.entityColumns) FROM entities
        WHERE deleted = 0 AND rowid IN (
            SELECT rowid FROM entities_fts WHERE entities_fts MATCH ? ORDER BY rank LIMIT ?
        )
        ORDER BY pinned DESC, updated_at DESC
        LIMIT ?
        """
        return try withStatement(sql) { stmt in
            try bindText(stmt, 1, match)
            try bindInt(stmt, 2, innerLimit)
            try bindInt(stmt, 3, bounded)
            return try sqlCollect(stmt, sql: sql, decode: Store.decodeEntity)
        }
    }

    /// Entities carrying this exact name, as either their title or one of their aliases.
    ///
    /// ``searchEntities(_:limit:)`` cannot find these: `entities_fts` indexes title and
    /// detail, and aliases live in a JSON column the FTS table never sees. So a memory that
    /// knows `Fenwick Migration` has the alias `FEN` answers "what is FEN-42 about" with
    /// nothing, despite holding the entity by name.
    ///
    /// Exact match rather than substring, on purpose. An alias is a short token (`FEN`,
    /// `ADR`, someone's initials) and a substring match on three characters would claim
    /// half the memory. The JSON encoding is what makes exactness cheap: every alias in the
    /// column is wrapped in quotes, so `"fen"` matches the alias and never the word inside
    /// `"fenwick migration"`.
    ///
    /// - Parameters:
    ///   - name: One name, already trimmed. Case-insensitive.
    ///   - limit: Maximum rows. Zero or negative means no limit.
    public func entitiesNamed(_ name: String, limit: Int) throws -> [Entity] {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let bounded = Store.sqlLimit(limit)
        // `aliases` is a JSON array, so the quotes are part of the stored text and give the
        // token boundary for free. Everything is lowered on both sides: SQLite's LIKE is
        // only case-insensitive over ASCII, and an alias may not be.
        let sql = """
        SELECT \(Schema.entityColumns) FROM entities
        WHERE deleted = 0
          AND (LOWER(title) = ? OR INSTR(LOWER(aliases), ?) > 0)
        ORDER BY (source = 'authored') DESC, pinned DESC, updated_at DESC
        LIMIT ?
        """
        return try withStatement(sql) { stmt in
            let lowered = trimmed.lowercased()
            try bindText(stmt, 1, lowered)
            try bindText(stmt, 2, "\"\(lowered)\"")
            try bindInt(stmt, 3, bounded)
            return try sqlCollect(stmt, sql: sql, decode: Store.decodeEntity)
        }
    }

    // MARK: - Provenance

    /// Records where one field of one entity came from.
    ///
    /// - Important: `entityID` is a foreign key. The entity must already exist or this throws
    ///   a constraint error. Always write an entity before its provenance.
    public func add(provenance: Provenance) throws {
        try ensureWritable()
        // The extractor mask is ORed, never replaced.
        //
        // This was `INSERT OR REPLACE`, which is correct for every other column and wrong for
        // this one: the row id is derived from entity, capture, field and snippet, so the two
        // passes finding the same evidence produce the same id. Replacing would mean the next
        // rules-only consolidation quietly erased the model's bit from a row they both found,
        // and the count this column exists to support would decay towards zero on its own.
        let sql = """
        INSERT INTO provenance (\(Schema.provenanceColumns))
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            entity_id = excluded.entity_id,
            capture_id = excluded.capture_id,
            field = excluded.field,
            snippet = excluded.snippet,
            ts = excluded.ts,
            extractor = provenance.extractor | excluded.extractor,
            -- The stronger reading wins, the way the extractor mask unions rather than
            -- overwrites. If one pass found these words in the title and another found them
            -- in the footer, the title is the true thing to say about the row.
            strength = CASE
                WHEN provenance.strength = 'direct' OR excluded.strength = 'direct' THEN 'direct'
                ELSE excluded.strength
            END
        """
        try withStatement(sql) { stmt in
            try bindText(stmt, 1, provenance.id)
            try bindText(stmt, 2, provenance.entityID)
            try bindText(stmt, 3, provenance.captureID)
            try bindText(stmt, 4, provenance.field)
            try bindText(stmt, 5, provenance.snippet)
            try bindDate(stmt, 6, provenance.ts)
            try bindInt(stmt, 7, provenance.extractor.rawValue)
            try bindText(stmt, 8, provenance.strength.rawValue)
            try sqlStep(stmt, sql: sql)
        }
    }

    /// Every provenance record for an entity, newest first.
    ///
    /// Records outlive their source capture: the stored `snippet` is what keeps an entity
    /// explainable after retention has removed the capture it came from.
    /// What the record can corroborate about each person, in one pass.
    ///
    /// Exists because the portrait needed to tell a person from a page. Measured on a real
    /// database: 261 "people", of whom 196 appeared on exactly one window title and never
    /// again: `typescript`, `framer` and `torvend` were all scraped off a single component
    /// library's marketing page, and `nordlysfoto` off a directory of wedding venues.
    ///
    /// The number that separates them is not how *often* a name was seen. Repetition is what
    /// a web page does. It is how many *different* places it was seen in, and how much of what
    /// was quoted is actually different text: Marco had seventy sightings carrying three
    /// distinct sentences, because the same chat window was read seventy times.
    ///
    /// One query rather than a fan-out, because the alternative is two round trips per person
    /// and there are hundreds of them.
    public struct Corroboration: Sendable, Equatable {
        public let entityID: ID
        /// Distinct window titles the name was ever seen on.
        public let pages: Int
        /// Distinct apps.
        public let apps: Int
        /// Distinct quoted text, as opposed to how many times it was re-read.
        public let distinctSnippets: Int
        /// Total sightings, kept for the honest version of "seen 70 times, saying 3 things".
        public let sightings: Int
        public let firstSeen: Date?
        public let lastSeen: Date?
    }

    public func corroboration(kind: EntityKind) throws -> [ID: Corroboration] {
        let sql = """
        SELECT e.id,
               COUNT(DISTINCT c.window_title),
               COUNT(DISTINCT c.app_name),
               COUNT(DISTINCT p.snippet),
               COUNT(p.id),
               MIN(p.ts), MAX(p.ts)
        FROM entities e
        JOIN provenance p ON p.entity_id = e.id
        LEFT JOIN captures c ON c.id = p.capture_id
        WHERE e.kind = ? AND e.deleted = 0
        GROUP BY e.id
        """
        let rows: [Corroboration] = try withStatement(sql) { stmt in
            try bindText(stmt, 1, kind.rawValue)
            return try sqlCollect(stmt, sql: sql) { stmt in
                Corroboration(
                    entityID: columnText(stmt, 0),
                    pages: Int(sqlite3_column_int(stmt, 1)),
                    apps: Int(sqlite3_column_int(stmt, 2)),
                    distinctSnippets: Int(sqlite3_column_int(stmt, 3)),
                    sightings: Int(sqlite3_column_int(stmt, 4)),
                    firstSeen: columnOptionalDate(stmt, 5),
                    lastSeen: columnOptionalDate(stmt, 6)
                )
            }
        }
        return Dictionary(uniqueKeysWithValues: rows.map { ($0.entityID, $0) })
    }

    /// How much evidence each pass has contributed, for the health check.
    ///
    /// Counting rows rather than entities because that is the level attribution lives at, and
    /// because an entity both passes found is a success for both. See ``ExtractorMask``.
    ///
    /// `unattributed` is rows written before schema v9. It is reported rather than folded into
    /// the rules' total, because pretending to know would be the same species of lie the mask
    /// exists to stop.
    public struct ExtractionYield: Sendable, Equatable {
        public let unattributed: Int
        public let rule: Int
        public let modelJSON: Int
        public let modelGuided: Int
        /// Rows the model produced by either path.
        public var model: Int { modelJSON + modelGuided }
        /// Evidence rows carrying any attribution at all.
        public var attributed: Int { rule + model }
    }

    /// True when this database has been migrated to carry extractor attribution (v9).
    ///
    /// Checked rather than assumed, because `--doctor` opens read-only and therefore cannot
    /// migrate: a memory written before v9 has no such column, and the health check has to say
    /// so rather than crash on the query it exists to run.
    public func hasExtractorAttribution() throws -> Bool {
        try withStatement("PRAGMA table_info(provenance)") { stmt in
            while sqlite3_step(stmt) == SQLITE_ROW {
                if columnText(stmt, 1) == "extractor" { return true }
            }
            return false
        }
    }

    /// Counts evidence by producing pass, optionally only rows newer than `since`.
    ///
    /// Returns `nil` when the database predates v9 and has nothing to count.
    public func extractionYield(since: Date? = nil) throws -> ExtractionYield? {
        guard try hasExtractorAttribution() else { return nil }
        return try countExtractionYield(since: since)
    }

    private func countExtractionYield(since: Date?) throws -> ExtractionYield {
        let clause = since == nil ? "" : "WHERE ts >= ?"
        let sql = """
        SELECT
            SUM(CASE WHEN extractor = 0 THEN 1 ELSE 0 END),
            SUM(CASE WHEN extractor & 1 THEN 1 ELSE 0 END),
            SUM(CASE WHEN extractor & 2 THEN 1 ELSE 0 END),
            SUM(CASE WHEN extractor & 4 THEN 1 ELSE 0 END)
        FROM provenance \(clause)
        """
        return try withStatement(sql) { stmt in
            if let since { try bindDate(stmt, 1, since) }
            var out = ExtractionYield(unattributed: 0, rule: 0, modelJSON: 0, modelGuided: 0)
            if sqlite3_step(stmt) == SQLITE_ROW {
                out = ExtractionYield(
                    unattributed: columnInt(stmt, 0),
                    rule: columnInt(stmt, 1),
                    modelJSON: columnInt(stmt, 2),
                    modelGuided: columnInt(stmt, 3)
                )
            }
            return out
        }
    }

    public func provenance(entityID: ID) throws -> [Provenance] {
        let sql = """
        SELECT \(Schema.provenanceColumns) FROM provenance
        WHERE entity_id = ?
        ORDER BY ts DESC
        """
        return try withStatement(sql) { stmt in
            try bindText(stmt, 1, entityID)
            return try sqlCollect(stmt, sql: sql, decode: Store.decodeProvenance)
        }
    }

    // MARK: - Sessions

    /// Inserts or updates a session by id.
    ///
    /// On update the window only ever widens (`started_at` takes the earlier value,
    /// `ended_at` the later one), which is what lets the capture loop extend the current
    /// session in place as the user keeps working.
    public func upsert(session: Session) throws {
        try ensureWritable()
        let sql = """
        INSERT INTO sessions (\(Schema.sessionColumns))
        VALUES (?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            app_bundle_id = excluded.app_bundle_id,
            app_name = excluded.app_name,
            started_at = min(sessions.started_at, excluded.started_at),
            ended_at = max(sessions.ended_at, excluded.ended_at),
            idle = excluded.idle
        """
        try withStatement(sql) { stmt in
            try bindText(stmt, 1, session.id)
            try bindText(stmt, 2, session.appBundleID)
            try bindText(stmt, 3, session.appName)
            try bindDate(stmt, 4, session.startedAt)
            try bindDate(stmt, 5, session.endedAt)
            try bindBool(stmt, 6, session.idle)
            try sqlStep(stmt, sql: sql)
        }
    }

    /// Sessions overlapping the closed interval `[from, to]`, oldest first.
    ///
    /// A session overlaps when it ended at or after `from` and started at or before `to`, so
    /// a session spanning the whole window is included.
    public func sessions(from: Date, to: Date) throws -> [Session] {
        let sql = """
        SELECT \(Schema.sessionColumns) FROM sessions
        WHERE ended_at >= ? AND started_at <= ?
        ORDER BY started_at ASC
        """
        return try withStatement(sql) { stmt in
            try bindDate(stmt, 1, from)
            try bindDate(stmt, 2, to)
            return try sqlCollect(stmt, sql: sql, decode: Store.decodeSession)
        }
    }

    // MARK: - Retention and maintenance

    /// Deletes captures older than `olderThan`. This is tier one of retention.
    ///
    /// Provenance rows are deliberately left alone: each carries its own snippet, so an
    /// entity stays explainable long after the capture that produced it has rolled off.
    ///
    /// - Returns: The number of capture rows deleted.
    @discardableResult
    public func purgeCaptures(olderThan: Date) throws -> Int {
        try ensureWritable()

        // Imported history is exempt. These rows are dated by when the thing happened rather
        // than by when Memoir read it, so a timestamp sweep would delete the decade the import
        // exists to provide, and it would do it the first time anybody set a window at all.
        // See `ImportedSource` for why deleting them protects nothing.
        let imported = Array(ImportedSource.bundleIDs)
        let placeholders = Array(repeating: "?", count: imported.count).joined(separator: ", ")
        let sql = "DELETE FROM captures WHERE ts < ? AND app_bundle_id NOT IN (\(placeholders))"
        try withStatement(sql) { stmt in
            try bindDate(stmt, 1, olderThan)
            for (offset, id) in imported.enumerated() {
                try bindText(stmt, Int32(offset + 2), id)
            }
            try sqlStep(stmt, sql: sql)
        }
        let deleted = changes()
        if deleted > 0 {
            Log.shared.info("purged \(deleted) captures older than \(olderThan)")
        }
        return deleted
    }

    /// Deletes everything belonging to the given bundle identifiers: captures, the provenance
    /// rows quoting them, and the sessions recording that the app was in front.
    ///
    /// For retiring a mistake. When an application is added to the default exclusion list it
    /// stops being read from that moment, and everything already recorded from it stays,
    /// which is no use at all if the reason it was excluded is that it should never have been
    /// read. `com.apple.SecurityAgent` was the case that prompted this: the exclusion list
    /// covered Keychain Access but not the credential sheet macOS puts in front of you, so
    /// real installations hold captures reading "enter the login keychain password".
    ///
    /// Unlike time-based retention this *does* take the provenance snippets, because the
    /// snippet is a verbatim quote of the text being retired and leaving it behind would
    /// defeat the point.
    ///
    /// **Sessions go too, and that is the whole reason this is not called `purgeCaptures`
    /// any more.** It used to take captures only, and a real installation showed what that
    /// leaves behind: `com.apple.SecurityAgent`, `com.apple.loginwindow` and
    /// `com.apple.UserNotificationCenter` held *zero* captures — the purge had run and
    /// worked — and 443 session rows totalling 77.5 hours, one of them a credential sheet
    /// frontmost for 596 seconds. A session is not text, but it is still a durable record
    /// that this app was in front of the user at this minute for this long, for an app whose
    /// text was deliberately destroyed, and nothing but `purgeEverything` could reach it.
    /// Sessions are also the presence signal work spans are built from, so five loginwindow
    /// rows cleared the work-span threshold and could be billed as work.
    ///
    /// - Returns: The number of capture rows deleted. Sessions are counted separately in the
    ///   log line: the caller's "did anything get retired" question is about text.
    @discardableResult
    public func purge(fromBundleIDs bundleIDs: Set<String>) throws -> Int {
        try ensureWritable()
        guard !bundleIDs.isEmpty else { return 0 }
        let db = try handle()
        let placeholders = Array(repeating: "?", count: bundleIDs.count).joined(separator: ", ")
        let ids = Array(bundleIDs)

        let provenanceSQL = """
        DELETE FROM provenance WHERE capture_id IN (
            SELECT id FROM captures WHERE app_bundle_id IN (\(placeholders))
        )
        """
        try withStatement(provenanceSQL) { stmt in
            for (offset, id) in ids.enumerated() { try bindText(stmt, Int32(offset + 1), id) }
            try sqlStep(stmt, sql: provenanceSQL)
        }

        let captureSQL = "DELETE FROM captures WHERE app_bundle_id IN (\(placeholders))"
        try withStatement(captureSQL) { stmt in
            for (offset, id) in ids.enumerated() { try bindText(stmt, Int32(offset + 1), id) }
            try sqlStep(stmt, sql: captureSQL)
        }
        // Read before the next DELETE runs. `changes()` reports the most recent statement
        // only, so reading it after the sessions delete would quietly make the log say it
        // purged captures when it counted sessions — a wrong number in the one place anyone
        // looks to find out whether this ran.
        let deleted = changes()

        let sessionSQL = "DELETE FROM sessions WHERE app_bundle_id IN (\(placeholders))"
        try withStatement(sessionSQL) { stmt in
            for (offset, id) in ids.enumerated() { try bindText(stmt, Int32(offset + 1), id) }
            try sqlStep(stmt, sql: sessionSQL)
        }
        let sessionsDeleted = changes()

        // Both counts gate the checkpoint, not just captures. On the installation that
        // prompted this the captures were already gone and only sessions remained, which is
        // exactly the case that must still reach the disk.
        if deleted > 0 || sessionsDeleted > 0 {
            try sqlExec(db, "PRAGMA wal_checkpoint(TRUNCATE);")
            Log.shared.info(
                "purged \(deleted) captures and \(sessionsDeleted) sessions from newly excluded apps")
        }
        return deleted
    }

    /// Imported history inside a date range, dated by the day it belongs to.
    ///
    /// Separate from ``captures(from:to:limit:)`` because it asks a different question with a
    /// different clock. A screen capture is bounded by an instant; imported history is bounded
    /// by a *date*, and the two stop agreeing the moment the reader's timezone differs from the
    /// importer's — which is the failure ``repairImportedDays(calendar:)`` exists to clean up
    /// after. Rows written since schema v10 carry the date they belong to and are matched on it.
    /// Older rows have no such column and fall back to their timestamp, which is the best that
    /// can be done for them.
    ///
    /// This is what stops `what_happened` answering "Nothing recorded" for a month with nine
    /// years of photographs behind it: sessions begin when Memoir was installed, and everything
    /// older than that is in here.
    public func importedCaptures(
        from: Date, to: Date, calendar: Calendar = .current, limit: Int = 5_000
    ) throws -> [CaptureEvent] {
        let bundles = Array(ImportedSource.bundleIDs)
        guard !bundles.isEmpty else { return [] }
        let placeholders = Array(repeating: "?", count: bundles.count).joined(separator: ", ")
        let bounded = Store.sqlLimit(limit)
        let sql = """
        SELECT \(Schema.captureColumns) FROM captures
        WHERE app_bundle_id IN (\(placeholders))
          AND (
                (local_day IS NOT NULL AND local_day >= ? AND local_day <= ?)
             OR (local_day IS NULL AND ts >= ? AND ts <= ?)
          )
        ORDER BY ts ASC
        \(bounded)
        """
        return try withStatement(sql) { stmt in
            var index: Int32 = 1
            for id in bundles { try bindText(stmt, index, id); index += 1 }
            try bindText(stmt, index, LifeImporter.localDayKey(from, calendar: calendar)); index += 1
            try bindText(stmt, index, LifeImporter.localDayKey(to, calendar: calendar)); index += 1
            try bindDate(stmt, index, from); index += 1
            try bindDate(stmt, index, to)
            return try sqlCollect(stmt, sql: sql, decode: Store.decodeCapture)
        }
    }

    /// Journal entries filed under a day in the given range, oldest first.
    ///
    /// The user's own words about their own days, which is the only authored layer this product
    /// has and the one thing in the memory nothing inferred. Asked for by `filed_at`, which is
    /// the column that exists to make this question askable at all — see ``Schema/v12``.
    public func journalEntries(from: Date, to: Date) throws -> [Entity] {
        let sql = """
        SELECT \(Schema.entityColumns) FROM entities
        WHERE filed_at IS NOT NULL AND deleted = 0 AND filed_at >= ? AND filed_at <= ?
        ORDER BY filed_at ASC, created_at ASC
        """
        return try withStatement(sql) { stmt in
            try bindDate(stmt, 1, from)
            try bindDate(stmt, 2, to)
            return try sqlCollect(stmt, sql: sql, decode: Store.decodeEntity)
        }
    }

    /// Marks commitments read off a browser tab as provisional, for rows written before the
    /// reading rule covered every tab.
    ///
    /// `RuleExtractor.isReadingSurface` used to exempt an allowlist of hosts — pull requests,
    /// inboxes, chats — on the reasoning that half the tools people write in are web apps.
    /// That is true and it is not evidence: you read a pull request far more often than you
    /// write one. Measured here, 308 open commitments came from a browser and 59 carried the
    /// flag, against ONE the user actually authored in seventy-five days.
    ///
    /// The extractor is fixed. This is for what it already wrote. A commitment is demoted when
    /// **every** capture behind it is a browser capture — if any piece of its evidence came
    /// from somewhere else, it is left alone, because the rule being applied is about where a
    /// sentence was read and mixed evidence does not establish that.
    ///
    /// Nothing is deleted. `provisional` keeps the row searchable and citable and only bars it
    /// from being asserted as a debt. Authored and corrected rows are never touched: those are
    /// the user's, and no sweep may overrule them.
    ///
    /// - Returns: how many commitments were demoted.
    @discardableResult
    public func repairBrowserCommitments(browserBundleIDs: Set<String>) throws -> Int {
        try ensureWritable()
        guard !browserBundleIDs.isEmpty else { return 0 }
        let placeholders = Array(repeating: "?", count: browserBundleIDs.count).joined(separator: ", ")
        let ids = Array(browserBundleIDs)
        let sql = """
        UPDATE entities SET provisional = 1
        WHERE kind = 'commitment' AND deleted = 0 AND provisional = 0
          AND source = 'inferred' AND corrected = 0
          AND EXISTS (SELECT 1 FROM provenance p WHERE p.entity_id = entities.id)
          AND NOT EXISTS (
                SELECT 1 FROM provenance p
                JOIN captures c ON c.id = p.capture_id
                WHERE p.entity_id = entities.id AND c.app_bundle_id NOT IN (\(placeholders))
          )
        """
        try withStatement(sql) { stmt in
            for (offset, id) in ids.enumerated() { try bindText(stmt, Int32(offset + 1), id) }
            try sqlStep(stmt, sql: sql)
        }
        let demoted = changes()
        if demoted > 0 {
            Log.shared.info("marked \(demoted) browser-read commitments provisional")
        }
        return demoted
    }

    /// Removes the given-name aliases the Contacts importer used to create.
    ///
    /// An alias is a licence to attach text to a person, and a first name is not a name for a
    /// person — it is a name for everyone who has it. The importer no longer emits them, but
    /// the rows it already wrote still carry them, and they are still live in two places.
    ///
    /// `MemoryService.consolidate` builds a `byAlias` index and reconciles any candidate whose
    /// title matches an alias into that entity, which is the merge itself: two cards sharing a
    /// first name, and whichever reached the index first absorbs what belongs to the other.
    /// `MemoryRank.linkedNames` then expands a search by alias, so one person's evidence is
    /// retrieved under the other's name. Measured on a real address book: 96 aliases across 95
    /// people, and **every one of them is a prefix of its own full name**. Not a single real
    /// nickname among them.
    ///
    /// So the rule is the importer's, applied backwards: an alias goes if it is a prefix of
    /// the title it belongs to, or if it is a single token. Anything a human actually typed —
    /// more than one word, not the start of the name — is left exactly where it is.
    ///
    /// Idempotent, and it cannot run away: it only ever removes, never writes a new alias.
    ///
    /// - Returns: how many aliases were removed.
    @discardableResult
    public func repairGivenNameAliases() throws -> Int {
        try ensureWritable()
        let people = try entities(kind: .person, includeDeleted: false)
        var removed = 0
        for person in people where !person.aliases.isEmpty {
            let title = MemoryText.normalizedTitle(person.title)
            let kept = person.aliases.filter { alias in
                let a = MemoryText.normalizedTitle(alias)
                if a.isEmpty { return false }
                if title.hasPrefix(a) { return false }
                return a.split(whereSeparator: \.isWhitespace).count > 1
            }
            guard kept.count != person.aliases.count else { continue }
            removed += person.aliases.count - kept.count
            var fixed = person
            fixed.aliases = kept
            // Straight through the SQL rather than `upsert`, because the merge law unions
            // aliases rather than replacing them — which is right when two passes disagree
            // about a person and exactly wrong when the job is to take one away.
            let sql = "UPDATE entities SET aliases = ? WHERE id = ?"
            try withStatement(sql) { stmt in
                try bindText(stmt, 1, Store.encodeAliases(fixed.aliases))
                try bindText(stmt, 2, fixed.id)
                try sqlStep(stmt, sql: sql)
            }
        }
        if removed > 0 { Log.shared.info("removed \(removed) given-name aliases from people") }
        return removed
    }

    /// Fills `filed_at` for journal entries written before the column existed.
    ///
    /// The one and only use of the accidental rule — an authored note with full confidence and
    /// no detail — and it runs once. A vault-imported note carries the file body in `detail`
    /// and a confidence below 1.0, so it is excluded by both halves; a note pushed from the
    /// chat is genuinely indistinguishable from a journal entry on an old database, and is
    /// filed under the day it was written, which is what it was about.
    ///
    /// Idempotent: rows that already carry a date are skipped, so a second pass does nothing.
    ///
    /// - Returns: how many rows were filed.
    @discardableResult
    public func repairJournalFiling() throws -> Int {
        try ensureWritable()
        let sql = """
        UPDATE entities SET filed_at = updated_at
        WHERE filed_at IS NULL AND deleted = 0
          AND kind = 'note' AND source = 'authored' AND confidence >= 1.0 AND detail IS NULL
        """
        try withStatement(sql) { stmt in try sqlStep(stmt, sql: sql) }
        let filed = changes()
        if filed > 0 { Log.shared.info("filed \(filed) journal entries written before v12") }
        return filed
    }

    /// Clears the duplicate imported rows the old day key minted, and fills `local_day`.
    ///
    /// Two repairs, both idempotent, both no-ops once there is nothing left to fix.
    ///
    /// **The duplicates.** `LifeImporter` used to key a photo day by rendering its *local*
    /// midnight through an ISO formatter, which defaults to UTC. The rendered string therefore
    /// carried the importing machine's offset, the id was derived from the string, and a
    /// library imported under two offsets minted two rows for every day. On the developer's
    /// vault that was 2,027 of 4,350 photo rows: exact twins, identical text, one hour apart,
    /// a memory that had lived through each of nine years twice. `LifeImporter.localDayKey`
    /// stops it happening again; this clears what already happened.
    ///
    /// Which twin survives is decided, not assumed. The keeper is whichever of the pair *is* a
    /// local midnight in the current calendar — 22:00Z in a UTC+2 summer, 23:00Z in a UTC+1
    /// winter, and the calendar knows which applies on that date. Only if neither qualifies
    /// does it fall back to the earlier row, and it never drops a row that has no twin.
    ///
    /// Provenance is repointed rather than deleted. The twins are byte-identical, so a snippet
    /// quoted from one is equally true of the other, and the evidence law says an entity keeps
    /// its citation.
    ///
    /// **The backfill** fills `local_day` for imported rows written before schema v10, from the
    /// current calendar. Those rows carry an unrecoverable ±1 day ambiguity — the offset they
    /// were written under is not stored anywhere — and this is the best available answer, not a
    /// correct one. Rows written from now on are authoritative.
    ///
    /// - Returns: How many duplicate rows were removed and how many dates were filled in.
    @discardableResult
    public func repairImportedDays(calendar: Calendar = .current) throws -> (removed: Int, dated: Int) {
        try ensureWritable()
        let bundles = Array(ImportedSource.bundleIDs)
        guard !bundles.isEmpty else { return (0, 0) }
        let placeholders = Array(repeating: "?", count: bundles.count).joined(separator: ", ")

        // ---- 1. the twins ----
        let pairSQL = """
        SELECT a.id, a.ts, b.id, b.ts
        FROM captures a
        JOIN captures b
          ON b.app_bundle_id = a.app_bundle_id
         AND b.ts = a.ts + 3600
         AND b.text = a.text
         AND IFNULL(b.window_title, '') = IFNULL(a.window_title, '')
        WHERE a.app_bundle_id IN (\(placeholders))
        """
        struct Pair { let keep: ID; let drop: ID }
        var pairs: [Pair] = []
        try withStatement(pairSQL) { stmt in
            for (offset, id) in bundles.enumerated() { try bindText(stmt, Int32(offset + 1), id) }
            while sqlite3_step(stmt) == SQLITE_ROW {
                let earlyID = columnText(stmt, 0)
                let earlyTS = columnDate(stmt, 1)
                let lateID = columnText(stmt, 2)
                let lateTS = columnDate(stmt, 3)
                let earlyIsMidnight = calendar.startOfDay(for: earlyTS) == earlyTS
                let lateIsMidnight = calendar.startOfDay(for: lateTS) == lateTS
                if lateIsMidnight && !earlyIsMidnight {
                    pairs.append(Pair(keep: lateID, drop: earlyID))
                } else {
                    pairs.append(Pair(keep: earlyID, drop: lateID))
                }
            }
        }

        for pair in pairs {
            let move = "UPDATE provenance SET capture_id = ? WHERE capture_id = ?"
            try withStatement(move) { stmt in
                try bindText(stmt, 1, pair.keep)
                try bindText(stmt, 2, pair.drop)
                try sqlStep(stmt, sql: move)
            }
            let kill = "DELETE FROM captures WHERE id = ?"
            try withStatement(kill) { stmt in
                try bindText(stmt, 1, pair.drop)
                try sqlStep(stmt, sql: kill)
            }
        }

        // ---- 2. the backfill ----
        let undatedSQL = """
        SELECT id, ts FROM captures
        WHERE local_day IS NULL AND app_bundle_id IN (\(placeholders))
        """
        var undated: [(ID, Date)] = []
        try withStatement(undatedSQL) { stmt in
            for (offset, id) in bundles.enumerated() { try bindText(stmt, Int32(offset + 1), id) }
            while sqlite3_step(stmt) == SQLITE_ROW {
                undated.append((columnText(stmt, 0), columnDate(stmt, 1)))
            }
        }
        for (id, ts) in undated {
            let sql = "UPDATE captures SET local_day = ? WHERE id = ?"
            try withStatement(sql) { stmt in
                try bindText(stmt, 1, LifeImporter.localDayKey(ts, calendar: calendar))
                try bindText(stmt, 2, id)
                try sqlStep(stmt, sql: sql)
            }
        }

        if !pairs.isEmpty || !undated.isEmpty {
            Log.shared.info(
                "repaired imported days: removed \(pairs.count) duplicates, dated \(undated.count) rows")
        }
        return (pairs.count, undated.count)
    }

    /// Hard-wipes everything (captures, entities, provenance, sessions and both full-text
    /// indexes) then `VACUUM`s so the bytes actually leave the disk.
    ///
    /// This is the "forget me" button. It is not recoverable.
    // MARK: - Semantic vectors

    /// Captures with no embedding yet, oldest first so a backlog drains in order.
    public func capturesMissingEmbeddings(limit: Int) throws -> [CaptureEvent] {
        let sql = """
        SELECT \(Schema.captureColumns) FROM captures
        WHERE id NOT IN (SELECT capture_id FROM capture_embeddings)
        ORDER BY ts ASC
        LIMIT ?
        """
        return try withStatement(sql) { stmt in
            try bindInt(stmt, 1, Store.sqlLimit(limit))
            return try sqlCollect(stmt, sql: sql, decode: Store.decodeCapture)
        }
    }

    /// Stores a vector for a capture.
    ///
    /// An empty array records "attempted, not embeddable", distinct from having no row at
    /// all, which means "not yet attempted". Without that distinction the backfill would
    /// retry the same unembeddable captures on every pass, forever.
    public func setEmbedding(captureID: ID, vector: [Float]) throws {
        try ensureWritable()
        let sql = """
        INSERT OR REPLACE INTO capture_embeddings (capture_id, vector, dimension)
        VALUES (?, ?, ?)
        """
        try withStatement(sql) { stmt in
            try bindText(stmt, 1, captureID)
            try bindBlob(stmt, 2, vector.withUnsafeBufferPointer { Data(buffer: $0) })
            try bindInt(stmt, 3, vector.count)
            try sqlStep(stmt, sql: sql)
        }
    }

    /// Captures that have a whole-capture vector but no passage vectors yet, oldest first.
    ///
    /// Deliberately not "every capture without passage vectors": a capture excluded from the
    /// semantic index (an empty vector: a conversation with an assistant, or text that would
    /// not embed) can never reach a search shortlist, so passage vectors for it would be work
    /// nobody will ever read.
    public func capturesMissingPassageVectors(limit: Int) throws -> [CaptureEvent] {
        let sql = """
        SELECT \(Schema.captureColumns) FROM captures
        WHERE id IN (SELECT capture_id FROM capture_embeddings WHERE LENGTH(vector) > 0)
          AND id NOT IN (SELECT capture_id FROM capture_passage_vectors)
        ORDER BY ts ASC
        LIMIT ?
        """
        return try withStatement(sql) { stmt in
            try bindInt(stmt, 1, Store.sqlLimit(limit))
            return try sqlCollect(stmt, sql: sql, decode: Store.decodeCapture)
        }
    }

    /// Stores every passage vector of one capture.
    ///
    /// The vectors are packed end to end into one blob, `count` rows of `dimension` floats,
    /// because a search reads all of a capture's passages or none of them. An empty array
    /// records "attempted, nothing embeddable", which is what stops the backfill retrying the
    /// same capture on every pass.
    ///
    /// - Precondition: every vector has the same dimension. Mixed dimensions cannot be packed
    ///   and are rejected rather than silently truncated.
    public func setPassageVectors(captureID: ID, vectors: [[Float]]) throws {
        try ensureWritable()
        let dimension = vectors.first?.count ?? 0
        guard vectors.allSatisfy({ $0.count == dimension }) else {
            throw MemoirError.storage("passage vectors for \(captureID) have mixed dimensions")
        }
        var flat: [Float] = []
        flat.reserveCapacity(vectors.count * dimension)
        for vector in vectors { flat.append(contentsOf: vector) }

        let sql = """
        INSERT OR REPLACE INTO capture_passage_vectors (capture_id, vectors, dimension, count)
        VALUES (?, ?, ?, ?)
        """
        try withStatement(sql) { stmt in
            try bindText(stmt, 1, captureID)
            try bindBlob(stmt, 2, flat.withUnsafeBufferPointer { Data(buffer: $0) })
            try bindInt(stmt, 3, dimension)
            try bindInt(stmt, 4, vectors.count)
            try sqlStep(stmt, sql: sql)
        }
    }

    /// Passage vectors for a set of captures, in one query.
    ///
    /// One statement rather than one per capture: a search re-scores a shortlist of dozens,
    /// and each round trip through this actor plus a prepare is pure overhead when the rows
    /// can be read in a single pass. Captures with no row are simply absent from the result,
    /// which is how the caller knows to compute them.
    public func passageVectors(for ids: [ID]) throws -> [ID: [[Float]]] {
        guard !ids.isEmpty else { return [:] }
        // SQLite caps bound parameters per statement (999 on older builds). A shortlist is 72
        // today, so this never splits in practice: it is here so that a caller asking for a
        // larger one gets a slower answer rather than an error.
        guard ids.count <= 500 else {
            var merged: [ID: [[Float]]] = [:]
            for chunk in stride(from: 0, to: ids.count, by: 500) {
                let slice = Array(ids[chunk..<min(chunk + 500, ids.count)])
                merged.merge(try passageVectors(for: slice)) { first, _ in first }
            }
            return merged
        }
        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
        let sql = """
        SELECT capture_id, vectors, dimension, count FROM capture_passage_vectors
        WHERE capture_id IN (\(placeholders))
        """
        let rows = try withStatement(sql) { stmt -> [(ID, [[Float]])] in
            for (offset, id) in ids.enumerated() {
                try bindText(stmt, Int32(offset + 1), id)
            }
            return try sqlCollect(stmt, sql: sql) { stmt -> (ID, [[Float]]) in
                let id = columnText(stmt, 0)
                let dimension = Int(sqlite3_column_int(stmt, 2))
                let count = Int(sqlite3_column_int(stmt, 3))
                let bytes = columnBlob(stmt, 1)
                guard dimension > 0, count > 0,
                      bytes.count == count * dimension * MemoryLayout<Float>.size else {
                    return (id, [])
                }
                let flat = bytes.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
                var vectors: [[Float]] = []
                vectors.reserveCapacity(count)
                for i in 0..<count {
                    vectors.append(Array(flat[(i * dimension)..<((i + 1) * dimension)]))
                }
                return (id, vectors)
            }
        }
        return Dictionary(rows, uniquingKeysWith: { first, _ in first })
    }

    /// Every stored vector, loaded wholesale for a brute-force scan.
    ///
    /// See ``SemanticIndex`` for why scanning beats an index at this corpus size, and for
    /// the measured threshold at which that stops being true.
    /// Every stored whole-capture vector, newest first, up to `limit`.
    ///
    /// The ordering is the point. This was `LIMIT ?` with no `ORDER BY`, so once the corpus
    /// passed `SemanticIndex.bruteForceCeiling` the scan silently covered an arbitrary
    /// rowid-ordered slice (in practice the *oldest* rows) and recall quietly stopped
    /// including this month. Truncating to the most recent is a defensible answer at that
    /// size; truncating to whatever SQLite happened to store first is not an answer at all.
    public func allEmbeddings(limit: Int) throws -> [(id: ID, vector: [Float])] {
        let sql = """
        SELECT e.capture_id, e.vector, e.dimension
        FROM capture_embeddings e
        JOIN captures c ON c.id = e.capture_id
        ORDER BY c.ts DESC
        LIMIT ?
        """
        return try withStatement(sql) { stmt in
            try bindInt(stmt, 1, Store.sqlLimit(limit))
            return try sqlCollect(stmt, sql: sql) { stmt -> (id: ID, vector: [Float]) in
                let id = columnText(stmt, 0)
                let dimension = Int(sqlite3_column_int(stmt, 2))
                let bytes = columnBlob(stmt, 1)
                guard dimension > 0, bytes.count == dimension * MemoryLayout<Float>.size else {
                    return (id: id, vector: [])
                }
                let vector = bytes.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
                return (id: id, vector: vector)
            }
        }
    }

    /// The pre-migration snapshots this store has left beside the database.
    ///
    /// `backUpBeforeMigrating` writes `memoir.sqlite.v{N}.backup` before each schema step and
    /// nothing has ever removed them, so upgrading through four versions leaves four complete
    /// plaintext copies of the entire memory on disk. Measured on a real installation: 66 MB
    /// of them beside a 42 MB database.
    public func migrationBackupURLs() -> [URL] {
        let directory = databaseURL.deletingLastPathComponent()
        let prefix = databaseURL.lastPathComponent + ".v"
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names
            .filter { $0.hasPrefix(prefix) && $0.hasSuffix(".backup") }
            .sorted()
            .map { directory.appendingPathComponent($0) }
    }

    /// Deletes pre-migration snapshots, keeping the `keepMostRecent` newest by schema version.
    ///
    /// Returns the number of bytes reclaimed. Called after a successful migration (one spare
    /// copy is insurance; four is a hoard) and with `keepMostRecent: 0` by `purgeEverything`.
    @discardableResult
    public func reapMigrationBackups(keepMostRecent: Int = 1) -> Int64 {
        let all = migrationBackupURLs()
        guard all.count > keepMostRecent else { return 0 }
        // Sorted by name, and the name ends in `.v{N}.backup`, so version order needs the
        // number rather than the string: v10 must not sort before v9.
        let byVersion = all.sorted { lhs, rhs in
            Self.backupVersion(lhs) < Self.backupVersion(rhs)
        }
        let doomed = byVersion.dropLast(keepMostRecent)
        var reclaimed: Int64 = 0
        for url in doomed {
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
            do {
                try FileManager.default.removeItem(at: url)
                reclaimed += size
                Log.shared.info("removed stale migration backup \(url.lastPathComponent)")
            } catch {
                Log.shared.warn("could not remove \(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return reclaimed
    }

    private static func backupVersion(_ url: URL) -> Int {
        let name = url.lastPathComponent
        guard let range = name.range(of: ".v", options: .backwards),
              let dot = name.range(of: ".backup", options: .backwards) else { return 0 }
        return Int(name[range.upperBound..<dot.lowerBound]) ?? 0
    }

    public func purgeEverything() throws {
        try ensureWritable()
        let db = try handle()

        try sqlExec(db, "BEGIN IMMEDIATE;")
        do {
            try sqlExec(
                db,
                """
                DELETE FROM provenance;
                DELETE FROM captures;
                DELETE FROM entities;
                DELETE FROM sessions;
                """
            )
            if hasFullTextSearch {
                try sqlExec(db, Schema.ftsDeleteAll)
            }
            try sqlExec(db, "COMMIT;")
        } catch {
            _ = sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
            throw error
        }

        // VACUUM cannot run inside a transaction, and the WAL must be folded in first or the
        // freed pages simply live on in the -wal file.
        try sqlExec(db, "PRAGMA wal_checkpoint(TRUNCATE);")
        // Checked after the checkpoint, when the -wal has been folded back and the size on
        // disk is the real one. The rows are gone either way; this only decides whether the
        // file can be compacted now or has to be compacted later.
        try ensureRoomToVacuum()
        try sqlExec(db, "VACUUM;")
        // And again afterwards, because in WAL mode VACUUM writes the entire rebuilt
        // database into the -wal rather than the main file. Without this second checkpoint
        // the folder stays exactly as large as it was until some later, unrelated write
        // happens to trigger one, so "delete everything" appeared to free nothing, which is
        // the one moment a user is actually watching the number.
        try sqlExec(db, "PRAGMA wal_checkpoint(TRUNCATE);")

        // The pre-migration snapshots go too, and they are the reason this had to change:
        // vacuuming the live file to near-nothing while leaving four whole copies of it in the
        // same folder is not "a real hard delete, not a flag", it is a delete the user can
        // disprove with `ls`. CF-7b requires those copies to exist; nothing required them to
        // survive the button that promises everything is gone.
        let reclaimed = reapMigrationBackups(keepMostRecent: 0)
        if reclaimed > 0 {
            Log.shared.info("reclaimed \(reclaimed) bytes of migration backups")
        }
        Log.shared.info("purged everything at \(databaseURL.path)")
    }

    /// Per-app capture quality over a trailing window, most-used apps first.
    ///
    /// See ``AppCaptureQuality`` for what the numbers mean and why they exist.
    public func captureQuality(since: Date) throws -> [AppCaptureQuality] {
        struct CaptureRow {
            let bundleID: String, appName: String
            let count: Int, chars: Int, titled: Int
            let last: Date?
        }
        // Memoir's own bookkeeping is excluded from BOTH sides.
        //
        // Vault notes and accepted proposals are recorded as captures for traceability;
        // the focus timer records sessions and by design never captures anything. Neither
        // is an app whose text Memoir is failing to read, and grading them produced a
        // coverage report (and a `--doctor` verdict) claiming "2 of 16 apps read poorly
        // or not at all: Memoir, Focus". An instrument that cries wolf about its own
        // bookkeeping is one nobody reads twice.
        // The `sh.pip.*` half names rows already written to disk before the rename: on the
        // database this was measured against, 73 of them. They are excluded for the same
        // reason as their `sh.memoir.*` equivalents, not out of nostalgia for the old name.
        let ownBundles = "'sh.memoir.app', 'sh.memoir.vault', 'sh.memoir.agent', 'sh.memoir.focus', "
            + "'sh.pip.app', 'sh.pip.vault', 'sh.pip.agent', 'sh.pip.focus'"
        let captureSQL = """
        SELECT app_bundle_id, app_name, COUNT(*), COALESCE(SUM(LENGTH(text)), 0),
               COALESCE(SUM(CASE WHEN window_title IS NOT NULL AND window_title != '' THEN 1 ELSE 0 END), 0),
               MAX(ts)
        FROM captures WHERE ts >= ? AND app_bundle_id NOT IN (\(ownBundles))
        GROUP BY app_bundle_id
        """
        let captureRows: [CaptureRow] = try withStatement(captureSQL) { stmt in
            try bindDate(stmt, 1, since)
            return try sqlCollect(stmt, sql: captureSQL) { stmt in
                CaptureRow(
                    bundleID: columnText(stmt, 0),
                    appName: columnText(stmt, 1),
                    count: Int(sqlite3_column_int64(stmt, 2)),
                    chars: Int(sqlite3_column_int64(stmt, 3)),
                    titled: Int(sqlite3_column_int64(stmt, 4)),
                    last: columnOptionalDate(stmt, 5)
                )
            }
        }

        let sessionSQL = """
        SELECT app_bundle_id, app_name, COALESCE(SUM(ended_at - started_at), 0)
        FROM sessions WHERE idle = 0 AND started_at >= ? AND app_bundle_id NOT IN (\(ownBundles))
        GROUP BY app_bundle_id
        """
        let sessionRows: [(bundleID: String, appName: String, seconds: Double)] =
            try withStatement(sessionSQL) { stmt in
                try bindDate(stmt, 1, since)
                return try sqlCollect(stmt, sql: sessionSQL) { stmt in
                    (
                        bundleID: columnText(stmt, 0),
                        appName: columnText(stmt, 1),
                        seconds: sqlite3_column_double(stmt, 2)
                    )
                }
            }

        let byBundle = Dictionary(uniqueKeysWithValues: captureRows.map { ($0.bundleID, $0) })
        let activeByBundle = Dictionary(uniqueKeysWithValues: sessionRows.map { ($0.bundleID, $0) })
        var bundles = Set(byBundle.keys)
        bundles.formUnion(activeByBundle.keys)

        return bundles.map { bundle -> AppCaptureQuality in
            let agg = byBundle[bundle]
            let active = activeByBundle[bundle]
            return AppCaptureQuality(
                bundleID: bundle,
                appName: agg?.appName ?? active?.appName ?? bundle,
                activeSeconds: active?.seconds ?? 0,
                captureCount: agg?.count ?? 0,
                capturedChars: agg?.chars ?? 0,
                titledShare: (agg?.count ?? 0) > 0 ? Double(agg!.titled) / Double(agg!.count) : 0,
                lastCapture: agg?.last
            )
        }
        .sorted { $0.activeSeconds > $1.activeSeconds }
    }

    /// Row counts, the oldest capture timestamp, and the on-disk size.
    ///
    /// `entityCount` counts live (non soft-deleted) entities, the number a user would
    /// recognise. `fileSizeBytes` is the database file plus its `-wal` and `-shm` sidecars,
    /// which is what the folder actually occupies.
    public func stats() throws -> StoreStats {
        let db = try handle()
        let sql = """
        SELECT
            (SELECT COUNT(*) FROM captures),
            (SELECT COUNT(*) FROM entities WHERE deleted = 0),
            (SELECT COUNT(*) FROM sessions),
            (SELECT MIN(ts) FROM captures),
            (SELECT MAX(ts) FROM captures),
            (SELECT MAX(ended_at) FROM sessions),
            (SELECT COUNT(DISTINCT date(ts, 'unixepoch', 'localtime')) FROM captures)
        """
        let row = try sqlOneRow(db, sql) { stmt in
            (
                captures: columnInt(stmt, 0),
                entities: columnInt(stmt, 1),
                sessions: columnInt(stmt, 2),
                oldest: columnOptionalDate(stmt, 3),
                newest: columnOptionalDate(stmt, 4),
                newestSession: columnOptionalDate(stmt, 5),
                activeDays: columnInt(stmt, 6)
            )
        }
        guard let row else {
            throw MemoirError.storage("stats query returned no row")
        }

        return StoreStats(
            captureCount: row.captures,
            entityCount: row.entities,
            sessionCount: row.sessions,
            oldestCapture: row.oldest,
            newestCapture: row.newest,
            newestSession: row.newestSession,
            fileSizeBytes: onDiskSize(),
            activeDays: row.activeDays
        )
    }

    // MARK: - Connection setup (nonisolated: runs during init)

    /// Opens a handle with the given flags, closing it again if the open half-succeeded.
    private static func openHandle(at path: URL, flags: Int32) throws -> OpaquePointer {
        var handle: OpaquePointer?
        let rc = sqlite3_open_v2(path.path, &handle, flags, nil)
        guard rc == SQLITE_OK, let handle else {
            // SQLite may hand back a usable handle even on failure so the message can be read.
            let error = sqliteError(handle, "open \(path.path)", code: rc)
            if let handle { sqlite3_close_v2(handle) }
            throw error
        }
        return handle
    }

    /// Applies the pragmas every Memoir connection needs.
    private static func configure(_ db: OpaquePointer, writable: Bool) throws {
        // Wait rather than fail when the app and the MCP server touch the file at once.
        try sqlExec(db, "PRAGMA busy_timeout = 5000;")
        try sqlExec(db, "PRAGMA foreign_keys = ON;")
        guard writable else { return }
        // WAL lets the read-only MCP connection read while the app writes.
        let mode = try sqlOneRow(db, "PRAGMA journal_mode = WAL;") { stmt in
            columnOptionalText(stmt, 0)
        } ?? nil
        if mode?.lowercased() != "wal" {
            Log.shared.warn("journal_mode is \(mode ?? "unknown"), expected wal")
        }
        try sqlExec(db, "PRAGMA synchronous = NORMAL;")
    }

    /// Runs every migration above the file's `user_version`.
    ///
    /// Each migration runs in its own `IMMEDIATE` transaction together with the
    /// `user_version` bump, so a crash mid-upgrade leaves the file on the previous version
    /// rather than half-migrated.
    /// Snapshots the database next to itself before a schema change.
    ///
    /// `VACUUM INTO` rather than a file copy or the backup API: it is one statement, it folds
    /// the WAL in (so the snapshot cannot be missing the most recent writes, which is the
    /// opposite of the point), and it writes a defragmented file. The backup API was tried
    /// first and produced an empty file here, which is the worst possible outcome - a backup
    /// that exists, reassures, and cannot be opened.
    private static func backUpBeforeMigrating(_ db: OpaquePointer, from version: Int32) throws {
        guard let path = sqlite3_db_filename(db, "main").map(String.init(cString:)),
              !path.isEmpty else { return }
        let backup = path + ".v\(version).backup"
        // One per version, never overwritten: an upgrade that runs twice must not clobber the
        // good copy with a half-migrated one.
        guard !FileManager.default.fileExists(atPath: backup) else { return }

        let quoted = backup.replacingOccurrences(of: "'", with: "''")
        if sqlite3_exec(db, "VACUUM INTO '\(quoted)';", nil, nil, nil) == SQLITE_OK {
            Log.shared.info("backed up v\(version) database to \(backup) before migrating")
        } else {
            // Never block the upgrade on a failed backup: a user who cannot migrate is worse
            // off than one who migrates without a spare copy. Loud, not fatal.
            Log.shared.warn("could not back up before migrating to v\(Schema.version): \(String(cString: sqlite3_errmsg(db)))")
            try? FileManager.default.removeItem(atPath: backup)
        }
    }

    /// Applies outstanding migrations.
    ///
    /// - Parameter consented: whether the caller is allowed to change the shape of an
    ///   EXISTING database. A fresh file is always initialised; that is creation, not
    ///   migration, and nobody can lose anything they had.
    ///
    /// Opening for read-write must not imply "and upgrade my schema". A migration is a
    /// one-way change to the only copy of everything the user has asked Memoir to remember, so
    /// it deserves what deleting deserves: asked for, not assumed.
    ///
    /// This is not hypothetical. `memoir-ask --embed`, a developer tool, silently migrated the
    /// user's live database from v3 to v4. The installed app was still a v3 build, refused to
    /// open it, and quit with "Memoir can't start". Nothing was lost and the database was
    /// perfect; the app was dead anyway. Only the app asks for this now.
    private static func migrate(_ db: OpaquePointer, consented: Bool) throws {
        var version = try userVersion(db)
        if version > Schema.version {
            // CF-7c, the half I missed. I made the READ-ONLY path tolerate a newer schema and
            // left this one throwing, then reported the flow as fixed. It bricked again the
            // moment a newer build touched the database first: "Memoir can't start" over a file
            // that was completely intact, which is the exact failure CF-7c exists to prevent.
            //
            // Migrations are additive by rule, so every column this build knows is still
            // there. Read it, say so, and change nothing: writing v4 shapes into a v5 file is
            // the one thing that could actually lose data here.
            Log.shared.warn(
                "database is v\(version), newer than this build (v\(Schema.version)). "
                + "Reading it without migrating; update Memoir to use everything in it."
            )
            return
        }

        // Copy the file before changing its shape.
        //
        // Not an agent-safety measure: a real user upgrading Memoir runs these same migrations
        // over the only copy of everything they have asked it to remember. A migration that
        // is buggy, or interrupted by a crash or a full disk, would take that with it and
        // there is nothing to restore from. The backup costs one file copy per version bump,
        // which happens a handful of times in the product's life.
        //
        // Kept beside the database with the version it was taken at, so it is obvious what it
        // is and which build wrote it.
        if version > 0, version < Schema.version {
            guard consented else {
                throw MemoirError.storage(
                    """
                    this database is v\(version) and this build writes v\(Schema.version). \
                    Open Memoir itself to upgrade it: a tool will not change your memory's shape \
                    behind the app's back.
                    """
                )
            }
            try? backUpBeforeMigrating(db, from: version)
        }

        for migration in Schema.migrations where migration.version > version {
            try sqlExec(db, "BEGIN IMMEDIATE;")
            do {
                // Statement by statement, so a replay can skip the one form of DDL
                // SQLite cannot make idempotent: `ALTER TABLE ADD COLUMN` has no
                // `IF NOT EXISTS`, and CF-7b deliberately replays the final migration
                // over a database that already has its shape (wind the version back,
                // reopen). "Duplicate column" on a replay means "already applied";
                // every other failure still aborts and rolls the whole step back.
                for statement in Self.statements(of: migration.sql) {
                    do {
                        try sqlExec(db, statement)
                    } catch let error as MemoirError {
                        guard case .storage(let message) = error,
                              message.contains("duplicate column name") else { throw error }
                        Log.shared.debug(
                            "migration v\(migration.version): \(message). Already applied, continuing")
                    }
                }
                // PRAGMA arguments cannot be bound; this value is a compile-time constant.
                try sqlExec(db, "PRAGMA user_version = \(migration.version);")
                try sqlExec(db, "COMMIT;")
            } catch {
                _ = sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
                throw error
            }
            version = migration.version
            Log.shared.info("migrated database to schema v\(version)")
        }
    }

    /// Splits a migration script into single statements.
    ///
    /// Safe for every migration in `Schema`: they are plain DDL with no string literals
    /// or trigger bodies containing semicolons. The FTS triggers live in `ftsSetup`,
    /// which never goes through here.
    private static func statements(of sql: String) -> [String] {
        sql.split(separator: ";")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Creates the FTS5 tables and their triggers if missing.
    ///
    /// - Returns: True when full-text search is usable. A SQLite build without FTS5 logs a
    ///   warning and returns false, so search falls back to `LIKE` rather than the whole
    ///   store failing to open.
    private static func installFullTextSearch(_ db: OpaquePointer) -> Bool {
        do {
            if try detectFullTextSearch(db) { return true }
            try sqlExec(db, Schema.ftsSetup)
            guard try detectFullTextSearch(db) else { return false }
            // The index is new; if the database already held rows (upgrade from a build
            // without FTS) it has to be built from them.
            try sqlExec(db, Schema.ftsRebuild)
            return true
        } catch {
            Log.shared.warn("full-text search unavailable, falling back to LIKE: \(error)")
            return false
        }
    }

    /// True when both full-text tables are present in the schema.
    private static func detectFullTextSearch(_ db: OpaquePointer) throws -> Bool {
        let sql = """
        SELECT COUNT(*) FROM sqlite_master
        WHERE type = 'table' AND name IN ('captures_fts', 'entities_fts')
        """
        let count = try sqlOneRow(db, sql) { stmt in columnInt(stmt, 0) }
        return count == 2
    }

    /// Reads `PRAGMA user_version`.
    private static func userVersion(_ db: OpaquePointer) throws -> Int32 {
        let value = try sqlOneRow(db, "PRAGMA user_version;") { stmt in columnInt(stmt, 0) }
        return Int32(truncatingIfNeeded: value ?? 0)
    }

    // MARK: - Isolated plumbing

    /// The live connection, or a clear error if the store was closed.
    private func handle() throws -> OpaquePointer {
        guard let connection else { throw MemoirError.storage("database is closed") }
        return connection.db
    }

    /// Rejects a write on a read-only connection before SQLite has to.
    func ensureWritable() throws {
        if isReadOnly {
            throw MemoirError.storage("store at \(databaseURL.path) is open read-only")
        }
    }

    /// Prepares, runs and finalizes one statement against the live connection.
    @discardableResult
    func withStatement<T>(_ sql: String, _ body: (OpaquePointer) throws -> T) throws -> T {
        try sqlWithStatement(try handle(), sql, body)
    }

    /// Rows changed by the most recent statement on this connection.
    private func changes() -> Int {
        guard let connection else { return 0 }
        return Int(sqlite3_changes(connection.db))
    }

    /// Size of the database plus its WAL sidecars, in bytes.
    /// Free space on the volume holding the database, or nil when it cannot be determined.
    public func freeSpaceBytes() -> Int64? {
        let values = try? databaseURL.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    /// Throws when a `VACUUM` would not fit.
    ///
    /// `VACUUM` rebuilds the database into a second file before swapping, so it needs roughly
    /// the size of the database again in free space. That makes "Delete everything" (the
    /// operation a user reaches for *because* the disk is full) the one most likely to fail
    /// on a full disk, and it used to fail silently after the DELETE had already committed:
    /// the stats panel emptied, the file never shrank, and nothing said why.
    private func ensureRoomToVacuum() throws {
        guard let free = freeSpaceBytes() else { return }
        let needed = onDiskSize() + 32 * 1_024 * 1_024
        guard free < needed else { return }
        let shortfall = ByteCountFormatter.string(fromByteCount: needed - free, countStyle: .file)
        throw MemoirError.storage(
            "not enough free space to compact the database: about \(shortfall) more is needed. "
            + "The records are already deleted; free some space and use Delete everything again "
            + "to reclaim the file."
        )
    }

    private func onDiskSize() -> Int64 {
        let manager = FileManager.default
        let paths = [
            databaseURL.path,
            databaseURL.path + "-wal",
            databaseURL.path + "-shm"
        ]
        var total: Int64 = 0
        for path in paths {
            guard let attributes = try? manager.attributesOfItem(atPath: path),
                  let size = attributes[.size] as? NSNumber else { continue }
            total += size.int64Value
        }
        return total
    }

    /// Normalises a caller-supplied limit into a SQLite `LIMIT` value, where -1 means "all".
    private static func sqlLimit(_ limit: Int) -> Int {
        limit > 0 ? limit : -1
    }

    // MARK: - Row decoding
    //
    // Column indices match the SELECT lists in `Schema`. These are static so a decoder can
    // never reach actor state in the middle of a step loop.

    private static func decodeCapture(_ stmt: OpaquePointer) -> CaptureEvent {
        CaptureEvent(
            id: columnText(stmt, 0),
            ts: columnDate(stmt, 1),
            appBundleID: columnText(stmt, 2),
            appName: columnText(stmt, 3),
            windowTitle: columnOptionalText(stmt, 4),
            text: columnText(stmt, 5),
            textHash: columnText(stmt, 6),
            visibleText: columnOptionalText(stmt, 7),
            localDay: columnOptionalText(stmt, 8)
        )
    }

    static func decodeEntity(_ stmt: OpaquePointer) -> Entity {
        let rawKind = columnText(stmt, 1)
        var kind = EntityKind(rawValue: rawKind)
        if kind == nil {
            Log.shared.warn("unknown entity kind '\(rawKind)', reading it as note")
            kind = .note
        }
        return Entity(
            id: columnText(stmt, 0),
            kind: kind ?? .note,
            title: columnText(stmt, 2),
            detail: columnOptionalText(stmt, 3),
            dueAt: columnOptionalDate(stmt, 4),
            confidence: columnDouble(stmt, 5),
            pinned: columnBool(stmt, 6),
            corrected: columnBool(stmt, 7),
            deleted: columnBool(stmt, 8),
            completedAt: columnOptionalDate(stmt, 12),
            // Unknown values read as inferred: the cautious direction. Treating an
            // unreadable source as authored would grant protection the data never earned.
            source: EntitySource(rawValue: columnText(stmt, 11)) ?? .inferred,
            aliases: Store.decodeAliases(columnText(stmt, 13)),
            provisional: columnBool(stmt, 14),
            filedAt: columnOptionalDate(stmt, 15),
            createdAt: columnDate(stmt, 9),
            updatedAt: columnDate(stmt, 10)
        )
    }

    private static func decodeProvenance(_ stmt: OpaquePointer) -> Provenance {
        Provenance(
            id: columnText(stmt, 0),
            entityID: columnText(stmt, 1),
            captureID: columnText(stmt, 2),
            field: columnText(stmt, 3),
            snippet: columnText(stmt, 4),
            ts: columnDate(stmt, 5),
            extractor: ExtractorMask(rawValue: columnInt(stmt, 6)),
            strength: EvidenceStrength(rawValue: columnText(stmt, 7)) ?? .direct
        )
    }

    private static func decodeSession(_ stmt: OpaquePointer) -> Session {
        Session(
            id: columnText(stmt, 0),
            appBundleID: columnText(stmt, 1),
            appName: columnText(stmt, 2),
            startedAt: columnDate(stmt, 3),
            endedAt: columnDate(stmt, 4),
            idle: columnBool(stmt, 5)
        )
    }
}
