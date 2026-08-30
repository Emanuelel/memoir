import Foundation
import MemoirKit

/// What the server found when it looked for Memoir's memory database.
public enum MemoryStatus: Sendable, Equatable {
    /// No database file exists yet: the app has never run, or ran with a different support directory.
    case missing(path: String)
    /// The file exists but SQLite could not read it.
    case unreadable(path: String, reason: String)
    /// The file opened but contains none of Memoir's tables.
    case noSchema(path: String, tables: [String])
    /// Usable, with a row census.
    case ready(path: String, captures: Int, entities: Int, sessions: Int, oldestCapture: Date?)

    /// True when queries can return real rows.
    public var isReady: Bool {
        if case .ready = self { return true }
        return false
    }

    /// The database path, whatever the outcome.
    public var path: String {
        switch self {
        case .missing(let p), .unreadable(let p, _), .noSchema(let p, _): return p
        case .ready(let p, _, _, _, _): return p
        }
    }
}

/// Read-only access to Memoir's memory database.
///
/// The actor owns a connection opened with `SQLITE_OPEN_READONLY` and
/// `PRAGMA query_only=ON`. It never issues a statement that could mutate state.
///
/// Column and table names are resolved from the live schema rather than
/// hard-coded, so the server keeps working if the writing side spells a column
/// `app_bundle_id` instead of `appBundleID`, and it degrades to "no data"
/// instead of failing when a table is absent.
public actor MemoirMemory {
    private let database: SQLiteReadOnly
    private var openResult: SQLiteReadOnly.OpenResult?
    private var schema: [String: [String]] = [:]
    private var maps: [Logical: TableMap] = [:]

    /// The database file this instance reads.
    public let path: URL

    /// Creates a reader. The file is opened lazily on first use.
    public init(path: URL) {
        self.path = path
        self.database = SQLiteReadOnly(path: path.path)
    }

    // MARK: - Logical schema

    /// The four tables the MCP surface needs.
    enum Logical: String, CaseIterable, Sendable {
        case captures, entities, provenance, sessions
    }

    /// A resolved table: its real name plus logical-field to real-column bindings.
    struct TableMap: Sendable {
        let table: String
        let columns: [String: String]
        /// How the primary timestamp column encodes dates, when it can be encoded back for SQL bounds.
        let timeCodec: DateCodec

        func column(_ logical: String) -> String? { columns[logical] }
        func has(_ logical: String) -> Bool { columns[logical] != nil }

        /// `"real" AS "logical"` for each requested field, `NULL AS "logical"` when absent.
        func selectList(_ fields: [String]) -> String {
            fields.map { field in
                if let real = columns[field] { return "\"\(real)\" AS \"\(field)\"" }
                return "NULL AS \"\(field)\""
            }.joined(separator: ", ")
        }

        /// A quoted `COALESCE`-joined haystack over the given text fields, for LIKE matching.
        func haystack(_ fields: [String]) -> String? {
            let present = fields.compactMap { columns[$0] }
            guard !present.isEmpty else { return nil }
            return "(" + present.map { "COALESCE(\"\($0)\",'')" }.joined(separator: " || ' ' || ") + ")"
        }
    }

    /// How a stored timestamp maps to a `Date`.
    enum DateCodec: Sendable, Equatable {
        case unixSeconds
        case unixMilliseconds
        /// Seconds since 2001-01-01, i.e. `Date.timeIntervalSinceReferenceDate`.
        case referenceSeconds
        case text
        case unknown

        /// Encodes a bound for use in SQL. `nil` when range filtering must happen in Swift.
        func bound(_ date: Date) -> SQLValue? {
            switch self {
            case .unixSeconds: return .double(date.timeIntervalSince1970)
            case .unixMilliseconds: return .double(date.timeIntervalSince1970 * 1000)
            case .referenceSeconds: return .double(date.timeIntervalSinceReferenceDate)
            case .text, .unknown: return nil
            }
        }

        /// Infers the encoding from one stored sample.
        static func infer(from value: SQLValue) -> DateCodec {
            switch value {
            case .text: return .text
            case .int, .double:
                guard let n = value.doubleValue else { return .unknown }
                if n > 1e11 { return .unixMilliseconds }
                if n > 1.2e9 { return .unixSeconds }
                if n > -1e9 { return .referenceSeconds }
                return .unknown
            default: return .unknown
            }
        }
    }

    private static let tableCandidates: [Logical: [String]] = [
        .captures: ["captures", "capture", "capture_events", "captureevents", "events"],
        .entities: ["entities", "entity"],
        .provenance: ["provenance", "provenances", "entity_provenance", "provenance_links"],
        .sessions: ["sessions", "session", "app_sessions"],
    ]

    /// Field resolution order matters: earlier fields claim their column first.
    private static let fieldCandidates: [Logical: [(String, [String])]] = [
        .captures: [
            ("id", ["id", "captureID", "uuid"]),
            ("appBundleID", ["appBundleID", "bundleID", "bundleIdentifier", "appBundle"]),
            ("appName", ["appName", "application", "app"]),
            ("windowTitle", ["windowTitle", "window"]),
            ("textHash", ["textHash", "hash", "sha", "sha256"]),
            ("text", ["text", "body", "content", "screenText"]),
            // Schema v8. Absent on any database written before it, which the resolver
            // reports as an unbound field and every reader below treats as "not known".
            ("visibleText", ["visibleText", "onScreenText"]),
            ("ts", ["ts", "timestamp", "capturedAt", "createdAt", "at", "time", "date"]),
            // Schema v10, imported rows only. Deliberately one candidate and no synonyms:
            // this is the date an imported row *belongs to*, and binding it to a loosely
            // named column would silently answer a different question than the one asked.
            ("localDay", ["localDay"]),
        ],
        .entities: [
            ("id", ["id", "entityID", "uuid"]),
            ("kind", ["kind", "entityKind", "type"]),
            ("title", ["title", "name", "label"]),
            ("detail", ["detail", "details", "summary", "body", "note"]),
            ("dueAt", ["dueAt", "due", "dueDate", "deadline"]),
            ("confidence", ["confidence", "score"]),
            ("pinned", ["pinned", "isPinned"]),
            ("corrected", ["corrected", "isCorrected", "userCorrected"]),
            ("deleted", ["deleted", "isDeleted"]),
            ("completedAt", ["completedAt", "doneAt", "completed"]),
            ("source", ["source", "entitySource", "origin"]),
            ("provisional", ["provisional", "isProvisional"]),
            ("aliases", ["aliases", "alias", "altNames"]),
            ("createdAt", ["createdAt", "created", "firstSeen"]),
            ("updatedAt", ["updatedAt", "updated", "modifiedAt", "lastSeen"]),
            ("filedAt", ["filedAt"]),
        ],
        .provenance: [
            ("id", ["id", "provenanceID", "uuid"]),
            ("entityID", ["entityID", "entity"]),
            ("captureID", ["captureID", "capture"]),
            ("field", ["field", "fieldName", "attribute"]),
            ("snippet", ["snippet", "excerpt", "quote", "text"]),
            ("ts", ["ts", "createdAt", "at", "time", "timestamp"]),
            // Schema v11. One candidate, no synonyms: a loosely named column bound here
            // would grade evidence by something that is not where it sat.
            ("strength", ["strength"]),
        ],
        .sessions: [
            ("id", ["id", "sessionID", "uuid"]),
            ("appBundleID", ["appBundleID", "bundleID", "bundleIdentifier", "appBundle"]),
            ("appName", ["appName", "application", "app"]),
            ("startedAt", ["startedAt", "start", "startTime", "began", "from"]),
            ("endedAt", ["endedAt", "end", "endTime", "finished", "to"]),
            ("idle", ["idle", "isIdle"]),
        ],
    ]

    private static let captureFields = [
        "id", "ts", "appBundleID", "appName", "windowTitle", "text", "textHash", "visibleText",
        "localDay",
    ]
    private static let entityFields = [
        "id", "kind", "title", "detail", "dueAt", "confidence",
        "pinned", "corrected", "deleted", "completedAt", "source", "provisional", "aliases",
        "filedAt", "createdAt", "updatedAt",
    ]
    private static let provenanceFields = [
        "id", "entityID", "captureID", "field", "snippet", "ts", "strength",
    ]
    private static let sessionFields = ["id", "appBundleID", "appName", "startedAt", "endedAt", "idle"]

    private static let primaryTimeField: [Logical: String] = [
        .captures: "ts", .entities: "updatedAt", .provenance: "ts", .sessions: "startedAt",
    ]

    // MARK: - Preparation

    /// Opens the file (once) and resolves the schema.
    @discardableResult
    private func prepare() -> SQLiteReadOnly.OpenResult {
        if let openResult { return openResult }
        let result = database.open()
        openResult = result
        guard result == .opened else {
            if case .failed(let reason) = result {
                MCPLog.error("cannot open \(path.path) read-only: \(reason)")
            } else {
                MCPLog.info("no database at \(path.path) yet")
            }
            return result
        }
        schema = database.introspectSchema()
        MCPLog.debug("schema tables: \(schema.keys.sorted().joined(separator: ", "))")
        for logical in Logical.allCases {
            if let map = resolve(logical) { maps[logical] = map }
        }
        let found = maps.keys.map(\.rawValue).sorted().joined(separator: ", ")
        MCPLog.info("opened \(path.path) read-only; mapped tables: \(found.isEmpty ? "none" : found)")
        return result
    }

    private static func normalized(_ s: String) -> String {
        s.lowercased().replacingOccurrences(of: "_", with: "")
    }

    private func resolve(_ logical: Logical) -> TableMap? {
        let candidates = Self.tableCandidates[logical] ?? [logical.rawValue]
        let wanted = candidates.map(Self.normalized)
        guard let table = schema.keys.first(where: { name in
            wanted.contains(Self.normalized(name))
        }) else { return nil }

        let actualColumns = schema[table] ?? []
        var used = Set<String>()
        var bound: [String: String] = [:]
        for (field, options) in Self.fieldCandidates[logical] ?? [] {
            let normalizedOptions = options.map(Self.normalized)
            for option in normalizedOptions {
                if let hit = actualColumns.first(where: { Self.normalized($0) == option && !used.contains($0) }) {
                    bound[field] = hit
                    used.insert(hit)
                    break
                }
            }
        }

        var codec = DateCodec.unknown
        if let timeField = Self.primaryTimeField[logical], let column = bound[timeField] {
            let sample = database.query(
                "SELECT \"\(column)\" AS t FROM \"\(table)\" WHERE \"\(column)\" IS NOT NULL LIMIT 1"
            ).first
            if let sample { codec = DateCodec.infer(from: sample["t"]) }
        }
        return TableMap(table: table, columns: bound, timeCodec: codec)
    }

    private func map(_ logical: Logical) -> TableMap? {
        prepare()
        return maps[logical]
    }

    // MARK: - Status

    /// Describes the database: missing, unreadable, schema-less, or ready with counts.
    public func status() -> MemoryStatus {
        let result = prepare()
        switch result {
        case .missing:
            return .missing(path: path.path)
        case .failed(let reason):
            return .unreadable(path: path.path, reason: reason)
        case .opened:
            break
        }
        guard !maps.isEmpty else {
            return .noSchema(path: path.path, tables: schema.keys.sorted())
        }
        let captures = count(.captures)
        let entities = count(.entities)
        let sessions = count(.sessions)
        var oldest: Date?
        if let capturesMap = maps[.captures], let ts = capturesMap.column("ts") {
            let row = database.query(
                "SELECT \"\(ts)\" AS t FROM \"\(capturesMap.table)\" WHERE \"\(ts)\" IS NOT NULL ORDER BY \"\(ts)\" ASC LIMIT 1"
            ).first
            oldest = row.flatMap { MemoirMemory.date(from: $0["t"]) }
        }
        return .ready(path: path.path, captures: captures, entities: entities, sessions: sessions, oldestCapture: oldest)
    }

    private func count(_ logical: Logical) -> Int {
        guard let map = maps[logical] else { return 0 }
        let row = database.query("SELECT count(*) AS n FROM \"\(map.table)\"").first
        return Int(row?["n"].intValue ?? 0)
    }

    // MARK: - Captures

    /// Full-text-ish search over capture text, window titles and app names.
    ///
    /// Uses `LIKE` rather than the FTS5 index so the query cannot depend on the
    /// writer's virtual-table naming, and so a corrupt or absent index never
    /// takes the server down. All terms must match; if that yields nothing, the
    /// search is retried with any-term matching.
    public func searchCaptures(_ query: String, limit: Int) -> [CaptureEvent] {
        guard let map = map(.captures), map.has("text") || map.has("windowTitle") else { return [] }
        guard let haystack = map.haystack(["text", "windowTitle", "appName"]) else { return [] }
        let terms = MemoirMemory.terms(in: query)
        guard !terms.isEmpty else { return recentCaptures(limit: limit) }

        let select = "SELECT \(map.selectList(Self.captureFields)) FROM \"\(map.table)\""
        let order = map.has("ts") ? " ORDER BY \"\(map.column("ts")!)\" DESC" : ""

        for joiner in ["AND", "OR"] {
            let clauses = terms.map { _ in "\(haystack) LIKE ? ESCAPE '\\'" }.joined(separator: " \(joiner) ")
            // Ask for the scan budget, not for `limit`.
            //
            // `LIMIT` used to bind `limit` directly, so SQL returned the N newest matching
            // rows and `isNotEvidence` then threw some away, leaving fewer than N, or
            // none, with the rest of the record never looked at. The failure is not
            // gradual and it is not rare, because the discarded rows are the *newest* by
            // construction: asking Claude about WhatsApp writes captures that say
            // "WhatsApp", and those outrank every real one on `ts DESC`. Ten rows fetched,
            // ten discarded as chatter, 322 genuine WhatsApp captures below the cut, and
            // the tool reports "nothing matched", so discussing a topic with an assistant
            // is what destroys your ability to recall it (CF-105).
            let binds = terms.map { SQLValue.text("%\(MemoirMemory.escapeLike($0))%") }
                + [.int(Int64(MemoirMemory.scanBudget(for: limit)))]
            let rows = database.query("\(select) WHERE \(clauses)\(order) LIMIT ?", binds)
            let found = rows.compactMap(MemoirMemory.capture(from:))
                .filter { !MemoirMemory.isNotEvidence($0) }
            if !found.isEmpty { return Array(found.prefix(limit)) }
            if terms.count == 1 { break }
        }
        return []
    }

    /// How many rows to ask SQL for when the answer is filtered afterwards.
    ///
    /// Any read that fetches `limit` rows and *then* drops some in Swift is not
    /// returning `limit` rows: it is returning however many survived, which is a
    /// number nobody chose. Over-fetch, filter, then trim: the budget is bounded so a
    /// pathological query cannot pull the table into memory.
    static func scanBudget(for limit: Int) -> Int {
        min(20_000, max(limit * 50, 2_000))
    }

    /// The most recent captures, newest first.
    ///
    /// Over-fetches for the same reason ``searchCaptures(_:limit:)`` does: an hour spent
    /// in an assistant is an hour of rows this filter drops, and binding `limit` to the
    /// query makes "the 10 most recent things you did" mean "whatever survives of the 10
    /// most recent rows", which, after a long chat session, is nothing (CF-105).
    public func recentCaptures(limit: Int) -> [CaptureEvent] {
        guard let map = map(.captures) else { return [] }
        let order = map.has("ts") ? " ORDER BY \"\(map.column("ts")!)\" DESC" : ""
        let rows = database.query(
            "SELECT \(map.selectList(Self.captureFields)) FROM \"\(map.table)\"\(order) LIMIT ?",
            [.int(Int64(MemoirMemory.scanBudget(for: limit)))]
        )
        return rows.compactMap(MemoirMemory.capture(from:))
            .filter { !MemoirMemory.isNotEvidence($0) }
            .prefix(max(1, limit))
            .map { $0 }
    }

    /// Captures inside a half-open-ish time range, newest first.
    ///
    /// The fast path used to skip ``isNotEvidence(_:)`` while all three of its neighbours
    /// applied it, so `working_set`, which is the tool an agent calls to load context and
    /// therefore the one that matters most, was the single reader that still returned
    /// assistant chatter. A filter three readers out of four apply is a filter that will be
    /// bypassed by whichever caller happens to pick the fourth.
    public func captures(from: Date, to: Date, limit: Int) -> [CaptureEvent] {
        guard let map = map(.captures), let ts = map.column("ts") else { return [] }
        let select = "SELECT \(map.selectList(Self.captureFields)) FROM \"\(map.table)\""
        if let lower = map.timeCodec.bound(from), let upper = map.timeCodec.bound(to) {
            let rows = database.query(
                "\(select) WHERE \"\(ts)\" >= ? AND \"\(ts)\" <= ? ORDER BY \"\(ts)\" DESC LIMIT ?",
                [lower, upper, .int(Int64(MemoirMemory.scanBudget(for: limit)))]
            )
            return rows.compactMap(MemoirMemory.capture(from:))
                .filter { !MemoirMemory.isNotEvidence($0) }
                .prefix(max(1, limit))
                .map { $0 }
        }
        // Unknown encoding: scan a bounded recent window and filter in Swift.
        //
        // This path had it right all along (over-fetch, filter, trim), while the fast
        // path above bound `limit` straight into SQL. The slow fallback was the correct
        // one and the optimised one was the bug (CF-105).
        let scan = MemoirMemory.scanBudget(for: limit)
        let rows = database.query("\(select) ORDER BY \"\(ts)\" DESC LIMIT ?", [.int(Int64(scan))])
        return rows.compactMap(MemoirMemory.capture(from:))
            .filter { $0.ts >= from && $0.ts <= to && !MemoirMemory.isNotEvidence($0) }
            .prefix(limit)
            .map { $0 }
    }

    /// What the user wrote about the days in a range, oldest first.
    ///
    /// The only authored layer in this memory. Everything else a tool returns is something
    /// Memoir inferred from a screen; this is the person's own sentence about their own day,
    /// and until schema v12 there was no way to ask for it — a journal entry and a note pushed
    /// from the chat were the same shape, so the six entries on the real vault ranked 20th,
    /// 149th, 15th, 53rd, 42nd and 97th inside their own days against a display cap of eight.
    /// None had ever reached an answer.
    ///
    /// Returns nothing on a database older than v12 rather than guessing with the accidental
    /// rule. The app fills the column once at launch; a tool must not invent the distinction.
    func journalEntries(from: Date, to: Date, limit: Int = 60) -> [Entity] {
        guard let map = map(.entities), map.has("filedAt"), let filed = map.column("filedAt")
        else { return [] }
        guard let lower = map.timeCodec.bound(from), let upper = map.timeCodec.bound(to) else { return [] }
        let deleted = map.column("deleted")
        let notDeleted = deleted.map { " AND COALESCE(\"\($0)\", 0) = 0" } ?? ""
        let rows = database.query(
            "SELECT \(map.selectList(Self.entityFields)) FROM \"\(map.table)\" "
            + "WHERE \"\(filed)\" IS NOT NULL AND \"\(filed)\" >= ? AND \"\(filed)\" <= ?"
            + "\(notDeleted) ORDER BY \"\(filed)\" ASC LIMIT ?",
            [lower, upper, .int(Int64(max(1, limit)))]
        )
        return rows.compactMap(MemoirMemory.entity(from:))
    }

    /// Imported history in a date range, matched on the day it belongs to.
    ///
    /// A different question from ``captures(from:to:limit:)`` with a different clock. A screen
    /// capture is bounded by an instant the user was present for. Imported history is bounded by
    /// a *date*, and the two stop agreeing the moment the reader's timezone differs from the
    /// importer's — the failure that duplicated half a photo library. Rows written since schema
    /// v10 carry the date they belong to and are matched on it; older rows have no such column
    /// and fall back to their timestamp, which is the best available for them.
    ///
    /// This is what stops `what_happened` answering "Nothing recorded" for a month with years of
    /// photographs behind it. Sessions begin when Memoir was installed; everything before that
    /// is here.
    ///
    /// Not filtered by ``isNotEvidence(_:)``: that guard exists to keep the assistant's own
    /// chatter out of answers, and an imported row is never assistant chatter.
    public func importedCaptures(
        from: Date, to: Date, calendar: Calendar = .current, limit: Int = 5_000
    ) -> [CaptureEvent] {
        guard let map = map(.captures),
              let ts = map.column("ts"),
              let bundle = map.column("appBundleID")
        else { return [] }
        let bundles = Array(ImportedSource.bundleIDs).sorted()
        guard !bundles.isEmpty else { return [] }

        let select = "SELECT \(map.selectList(Self.captureFields)) FROM \"\(map.table)\""
        let inList = bundles.map { _ in "?" }.joined(separator: ", ")
        var params: [SQLValue] = bundles.map { .text($0) }

        // The day predicate, when the column exists. Older databases keep the timestamp path,
        // which is what they have.
        var dayClause = ""
        if let day = map.column("localDay") {
            dayClause = "(\"\(day)\" IS NOT NULL AND \"\(day)\" >= ? AND \"\(day)\" <= ?) OR "
            params.append(.text(LifeImporter.localDayKey(from, calendar: calendar)))
            params.append(.text(LifeImporter.localDayKey(to, calendar: calendar)))
        }
        guard let lower = map.timeCodec.bound(from), let upper = map.timeCodec.bound(to) else {
            return []
        }
        let tsClause = map.column("localDay") == nil
            ? "\"\(ts)\" >= ? AND \"\(ts)\" <= ?"
            : "(\"\(map.column("localDay")!)\" IS NULL AND \"\(ts)\" >= ? AND \"\(ts)\" <= ?)"
        params.append(lower)
        params.append(upper)
        params.append(.int(Int64(max(1, limit))))

        let rows = database.query(
            "\(select) WHERE \"\(bundle)\" IN (\(inList)) AND (\(dayClause)\(tsClause)) "
            + "ORDER BY \"\(ts)\" ASC LIMIT ?",
            params
        )
        return rows.compactMap(MemoirMemory.capture(from:))
    }

    /// Looks several captures up by id in one statement.
    public func captures(ids: [ID]) -> [ID: CaptureEvent] {
        let unique = Array(Set(ids)).filter { !$0.isEmpty }
        guard !unique.isEmpty, let map = map(.captures), map.has("id") else { return [:] }
        var found: [ID: CaptureEvent] = [:]
        // Chunked to stay well inside SQLITE_MAX_VARIABLE_NUMBER.
        for chunk in stride(from: 0, to: unique.count, by: 100).map({ Array(unique[$0..<min($0 + 100, unique.count)]) }) {
            let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            let rows = database.query(
                "SELECT \(map.selectList(Self.captureFields)) FROM \"\(map.table)\" WHERE \"\(map.column("id")!)\" IN (\(placeholders))",
                chunk.map { SQLValue.text($0) }
            )
            for capture in rows.compactMap(MemoirMemory.capture(from:))
            where !MemoirMemory.isNotEvidence(capture) {
                found[capture.id] = capture
            }
        }
        return found
    }

    // MARK: - Entities

    /// Search over entity titles and details. Soft-deleted rows are dropped.
    public func searchEntities(_ query: String, limit: Int) -> [Entity] {
        guard let map = map(.entities), let haystack = map.haystack(["title", "detail"]) else { return [] }
        let terms = MemoirMemory.terms(in: query)
        guard !terms.isEmpty else { return allEntities(limit: limit) }

        let select = "SELECT \(map.selectList(Self.entityFields)) FROM \"\(map.table)\""
        let order = map.has("updatedAt") ? " ORDER BY \"\(map.column("updatedAt")!)\" DESC" : ""
        for joiner in ["AND", "OR"] {
            let clauses = terms.map { _ in "\(haystack) LIKE ? ESCAPE '\\'" }.joined(separator: " \(joiner) ")
            let binds = terms.map { SQLValue.text("%\(MemoirMemory.escapeLike($0))%") } + [.int(Int64(max(1, limit) * 3))]
            let rows = database.query("\(select) WHERE \(clauses)\(order) LIMIT ?", binds)
            let live = rows.compactMap(MemoirMemory.entity(from:)).filter { !$0.deleted }
            if !live.isEmpty { return Array(live.prefix(limit)) }
            if terms.count == 1 { break }
        }
        return []
    }

    /// Every live entity, most recently updated first.
    public func allEntities(limit: Int = 5_000) -> [Entity] {
        guard let map = map(.entities) else { return [] }
        let order = map.has("updatedAt") ? " ORDER BY \"\(map.column("updatedAt")!)\" DESC" : ""
        let rows = database.query(
            "SELECT \(map.selectList(Self.entityFields)) FROM \"\(map.table)\"\(order) LIMIT ?",
            [.int(Int64(max(1, limit)))]
        )
        return rows.compactMap(MemoirMemory.entity(from:)).filter { !$0.deleted }
    }

    /// Live entities of one kind. Filtering happens in Swift so the server does
    /// not have to guess how the writer encodes `EntityKind`.
    public func entities(kind: EntityKind, limit: Int = 5_000) -> [Entity] {
        allEntities(limit: limit).filter { $0.kind == kind }
    }

    /// Entities created or updated inside a range.
    public func entitiesTouched(from: Date, to: Date) -> [Entity] {
        allEntities().filter { entity in
            (entity.updatedAt >= from && entity.updatedAt <= to)
                || (entity.createdAt >= from && entity.createdAt <= to)
        }
    }

    // MARK: - Provenance

    /// Provenance rows for one entity, newest first.
    public func provenance(entityID: ID, limit: Int = 12) -> [Provenance] {
        guard let map = map(.provenance), let entityColumn = map.column("entityID") else { return [] }
        let order = map.has("ts") ? " ORDER BY \"\(map.column("ts")!)\" DESC" : ""
        let rows = database.query(
            "SELECT \(map.selectList(Self.provenanceFields)) FROM \"\(map.table)\" WHERE \"\(entityColumn)\" = ?\(order) LIMIT ?",
            [.text(entityID), .int(Int64(max(1, limit)))]
        )
        return rows.compactMap(MemoirMemory.provenanceRow(from:))
    }

    // MARK: - Sessions

    /// Sessions overlapping a range, newest first.
    public func sessions(from: Date, to: Date, limit: Int = 5_000) -> [Session] {
        guard let map = map(.sessions), let start = map.column("startedAt") else { return [] }
        let select = "SELECT \(map.selectList(Self.sessionFields)) FROM \"\(map.table)\""
        if let lower = map.timeCodec.bound(from), let upper = map.timeCodec.bound(to), let end = map.column("endedAt") {
            let rows = database.query(
                "\(select) WHERE \"\(start)\" <= ? AND COALESCE(\"\(end)\", \"\(start)\") >= ? ORDER BY \"\(start)\" DESC LIMIT ?",
                [upper, lower, .int(Int64(max(1, limit)))]
            )
            return rows.compactMap(MemoirMemory.session(from:))
        }
        let rows = database.query("\(select) ORDER BY \"\(start)\" DESC LIMIT ?", [.int(Int64(min(20_000, max(limit, 2_000))))])
        return rows.compactMap(MemoirMemory.session(from:)).filter { $0.startedAt <= to && $0.endedAt >= from }
    }

    // MARK: - Row decoding

    private static func capture(from row: SQLRow) -> CaptureEvent? {
        let id = row["id"].textValue ?? UUID().uuidString.lowercased()
        return CaptureEvent(
            id: id,
            ts: date(from: row["ts"]) ?? Date(timeIntervalSince1970: 0),
            appBundleID: row["appBundleID"].textValue ?? "",
            appName: row["appName"].textValue ?? row["appBundleID"].textValue ?? "Unknown app",
            windowTitle: row["windowTitle"].textValue,
            text: row["text"].textValue ?? "",
            textHash: row["textHash"].textValue ?? "",
            visibleText: row["visibleText"].textValue,
            localDay: row["localDay"].textValue
        )
    }

    private static func entity(from row: SQLRow) -> Entity? {
        guard let title = row["title"].textValue, !title.isEmpty else { return nil }
        let now = Date()
        // Bound separately: with every argument inline the type-checker gives up on this
        // initialiser. Cheap to keep, and it fails as a compile error rather than a slow build.
        let id: String = row["id"].textValue ?? UUID().uuidString.lowercased()
        let confidence: Double = row["confidence"].doubleValue ?? 0.5
        let pinned: Bool = row["pinned"].boolValue ?? false
        let corrected: Bool = row["corrected"].boolValue ?? false
        let deleted: Bool = row["deleted"].boolValue ?? false
        let source: EntitySource = row["source"].textValue.flatMap(EntitySource.init(rawValue:)) ?? .inferred
        let provisional: Bool = row["provisional"].boolValue ?? false
        let aliases: [String] = decodeAliases(row["aliases"].textValue)
        let createdAt: Date = date(from: row["createdAt"]) ?? now
        let updatedAt: Date = date(from: row["updatedAt"]) ?? createdAt
        return Entity(
            id: id,
            kind: kind(from: row["kind"]),
            title: title,
            detail: row["detail"].textValue,
            dueAt: date(from: row["dueAt"]),
            confidence: confidence,
            pinned: pinned,
            corrected: corrected,
            deleted: deleted,
            // Pre-v5/v6 files have none of these columns; absent reads as open,
            // inferred and unaliased, the same defaults the writer's migrations backfill.
            //
            // `provisional` is the same rule with a harder lesson: the column has to be
            // ASKED FOR to be absent honestly. It was missing from `entityFields`, so every
            // row decoded as false and the two `!provisional` filters in ToolHandler were
            // dead code. CF-79 held in the app and silently did not hold on the surface
            // agents actually read from (CF-90).
            completedAt: date(from: row["completedAt"]),
            source: source,
            aliases: aliases,
            provisional: provisional,
            // Schema v12: non-null means a person wrote about a day. Absent on an older
            // database, where it reads as nil and the journal simply cannot be isolated —
            // which is the state this column exists to end.
            filedAt: date(from: row["filedAt"]),
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    /// Aliases are stored as a JSON array string; anything unreadable is no aliases.
    private static func decodeAliases(_ text: String?) -> [String] {
        guard let text, text != "[]", let data = text.data(using: .utf8),
              let list = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return list
    }

    private static func provenanceRow(from row: SQLRow) -> Provenance? {
        guard let entityID = row["entityID"].textValue else { return nil }
        return Provenance(
            id: row["id"].textValue ?? UUID().uuidString.lowercased(),
            entityID: entityID,
            captureID: row["captureID"].textValue ?? "",
            field: row["field"].textValue ?? "unknown",
            snippet: row["snippet"].textValue ?? "",
            ts: date(from: row["ts"]) ?? Date(timeIntervalSince1970: 0),
            // Absent on a database written before schema v11, and read as `direct` there —
            // which is what every read path already implied about those rows.
            strength: EvidenceStrength(rawValue: row["strength"].textValue ?? "") ?? .direct
        )
    }

    private static func session(from row: SQLRow) -> Session? {
        guard let started = date(from: row["startedAt"]) else { return nil }
        let ended = date(from: row["endedAt"]) ?? started
        return Session(
            id: row["id"].textValue ?? UUID().uuidString.lowercased(),
            appBundleID: row["appBundleID"].textValue ?? "",
            appName: row["appName"].textValue ?? row["appBundleID"].textValue ?? "Unknown app",
            startedAt: started,
            endedAt: max(ended, started),
            idle: row["idle"].boolValue ?? false
        )
    }

    private static func kind(from value: SQLValue) -> EntityKind {
        if let text = value.textValue, let parsed = EntityKind(rawValue: text.lowercased()) { return parsed }
        if let index = value.intValue, index >= 0, Int(index) < EntityKind.allCases.count {
            return EntityKind.allCases[Int(index)]
        }
        return .note
    }

    /// Decodes a stored timestamp without assuming one encoding.
    ///
    /// Numbers above 1e11 are milliseconds since 1970, above 1.2e9 are seconds
    /// since 1970, anything smaller is seconds since the 2001 reference date
    /// (`Date.timeIntervalSinceReferenceDate`, which Swift code stores often).
    /// Text is parsed as ISO-8601, with a SQL `datetime()` fallback.
    static func date(from value: SQLValue) -> Date? {
        switch value {
        case .null, .blob:
            return nil
        case .int, .double:
            guard let n = value.doubleValue, n.isFinite, n != 0 else { return nil }
            if n > 1e11 { return Date(timeIntervalSince1970: n / 1000) }
            if n > 1.2e9 { return Date(timeIntervalSince1970: n) }
            return Date(timeIntervalSinceReferenceDate: n)
        case .text(let raw):
            let text = raw.trimmingCharacters(in: .whitespaces)
            if text.isEmpty { return nil }
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: text) { return date }
            let plain = ISO8601DateFormatter()
            plain.formatOptions = [.withInternetDateTime]
            if let date = plain.date(from: text) { return date }
            if let number = Double(text) { return MemoirMemory.date(from: .double(number)) }
            // SQLite `datetime()` default: "YYYY-MM-DD HH:MM:SS" in UTC.
            let sqlFormatter = DateFormatter()
            sqlFormatter.locale = Locale(identifier: "en_US_POSIX")
            sqlFormatter.timeZone = TimeZone(secondsFromGMT: 0)
            sqlFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
            if let date = sqlFormatter.date(from: text) { return date }
            sqlFormatter.dateFormat = "yyyy-MM-dd"
            return sqlFormatter.date(from: text)
        }
    }

    // MARK: - Query text helpers

    /// Splits a query into up to six searchable terms.
    /// True when a capture is a conversation with a model rather than something seen.
    ///
    /// What you *asked* is not what you *saw*, and only the latter is evidence. A chat
    /// with an assistant contains prompts and generated replies, including replies that
    /// quote this memory's own output back at it, so citing one as fact is circular: an
    /// agent reads its own earlier suggestion and treats it as the user's decision.
    ///
    /// Measured on a real database: 1,029 captures from an assistant desktop app, 54
    /// entities citing them, and no filter anywhere in this server. The writer has refused
    /// to cite these since the day it served a documented wrong answer back as truth; this
    /// is the same rule for the surface agents actually read from.
    ///
    /// Duplicated here rather than shared, deliberately: this server knows nothing about
    /// the writer's internals, which is what lets it read a database it did not create.
    /// True when a capture is not evidence of anything the user saw or did.
    ///
    /// The single gate every capture leaves this server through. Two things fail it, for the
    /// same underlying reason (both are the memory's own reflection rather than the world):
    /// a conversation with an assistant, and Memoir's own window.
    ///
    /// Memoir's window was the gap. ``isAssistantConversation(_:)`` catches Claude and
    /// ChatGPT, but Memoir's ask bar displays Memoir's ANSWERS, and the capture loop reads
    /// the screen it is drawn on. So an answer becomes a capture, the capture is returned as
    /// memory, and the memory is cited as evidence for the answer that produced it. The app
    /// has refused to cite `sh.memoir.app` since `renderMostRecent` was written; this server
    /// had no such rule, which made it the one surface where the loop could close.
    static func isNotEvidence(_ capture: CaptureEvent) -> Bool {
        isAssistantConversation(capture) || isMemoirsOwnWindow(capture)
    }

    /// True when Memoir is looking at itself. Not somewhere the user was.
    static func isMemoirsOwnWindow(_ capture: CaptureEvent) -> Bool {
        capture.appBundleID == "sh.memoir.app"
    }

    static func isAssistantConversation(_ capture: CaptureEvent) -> Bool {
        let bundles: Set<String> = [
            "com.anthropic.claudefordesktop", "com.openai.chat", "com.google.gemini",
            "com.perplexity.desktop", "com.microsoft.copilot",
        ]
        if bundles.contains(capture.appBundleID) { return true }
        // In a browser tab the bundle ID says "Chrome" and only the title gives it away.
        let haystack = ((capture.windowTitle ?? "") + " " + capture.appName).lowercased()
        if ["claude.ai", "chatgpt.com", "chat.openai.com", "gemini.google.com",
            "perplexity.ai", "copilot.microsoft.com"].contains(where: { haystack.contains($0) }) {
            return true
        }
        return isAssistantTabTitle(capture)
    }

    /// Browsers Memoir recognises, so a title heuristic is only applied to a page.
    private static let browserBundles: Set<String> = [
        "com.google.Chrome", "com.apple.Safari", "org.mozilla.firefox",
        "com.microsoft.edgemac", "company.thebrowser.Browser", "com.brave.Browser",
        "com.operasoftware.Opera", "com.vivaldi.Vivaldi",
    ]

    /// Assistant products whose name, standing alone as a title segment, means the tab *is*
    /// that product.
    ///
    /// Gemini is deliberately absent. It is a crypto exchange, an Apollo programme and a star
    /// sign before it is an assistant, so a bare "Gemini" segment is not evidence of one; the
    /// domain check above still catches `gemini.google.com`. The others are distinctive enough
    /// that a page titled only "Claude" or "Perplexity" is the product itself.
    private static let assistantProducts: Set<String> = [
        "claude", "chatgpt", "perplexity", "copilot",
    ]

    /// True when a browser tab's title says the page is an assistant, without naming its domain.
    ///
    /// The domain check above missed every conversation held in the Claude web app, because the
    /// tab is titled `Test question - Claude – Part of group ✅Memoir demo video with Remotion`
    /// and `claude.ai` appears nowhere in it. Six of ten rows in a `recall` for "WhatsApp" came
    /// back as this: Memoir quoting Claude telling the user it cannot read their WhatsApp,
    /// offered as evidence of their WhatsApp.
    ///
    /// Matched on whole segments rather than as a substring, which is the entire difference
    /// between a filter and a shredder. On this database `contains("claude")` would have taken
    /// 87 browser captures, nearly all of them the user genuinely reading about Claude:
    /// `mirafenn on X: "…this literally just feels like Claude skills…"`, `claude demo - Search / X`,
    /// `How to Run a Gauntlet Loop: … Behind Claude of Duty`. Those are evidence, and of exactly
    /// the kind this product exists to keep. Splitting on the separators a browser actually uses
    /// and requiring an exact segment keeps all of them and still drops every real conversation:
    /// "Claude of Duty" is a segment, "Claude" is not.
    static func isAssistantTabTitle(_ capture: CaptureEvent) -> Bool {
        guard browserBundles.contains(capture.appBundleID), let title = capture.windowTitle
        else { return false }
        // Browsers join the page title, the tab-group label and their own name with a mix of
        // hyphen, en dash and em dash. Normalise before splitting so one form is enough.
        let normalised = title
            .replacingOccurrences(of: " – ", with: " - ")
            .replacingOccurrences(of: " \u{2014} ", with: " - ")
            .replacingOccurrences(of: " | ", with: " - ")
        return normalised
            .components(separatedBy: " - ")
            .contains { segment in
                assistantProducts.contains(
                    segment.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                )
            }
    }

    /// Words too common to be evidence of anything.
    ///
    /// Kept here rather than borrowed from the writer: this server deliberately knows
    /// nothing about the app's internals, and the list only has to be good enough to stop
    /// a claim being "supported" by the word "the".
    static let commonWords: Set<String> = [
        "the", "and", "for", "with", "that", "this", "from", "into", "was", "were", "are",
        "is", "be", "been", "being", "has", "have", "had", "will", "would", "should",
        "could", "can", "may", "might", "must", "shall", "does", "did", "not", "but",
        "all", "any", "some", "there", "here", "what", "when", "where", "who", "why",
        "how", "which", "than", "then", "too", "very", "just", "only", "also", "about",
        "over", "under", "after", "before", "made", "make", "get", "got", "one", "two",
        "new", "old", "now", "you", "your", "our", "their", "his", "her", "its", "it",
        "on", "in", "at", "of", "to", "as", "by", "or", "if", "so", "we", "i", "a", "an",
        "everything", "nothing", "something", "anything", "fine", "matter", "runs", "run",
    ]

    /// The words in a claim that could actually distinguish it from any other sentence.
    ///
    /// `verify` lives or dies on this. Its first implementation searched on every word and
    /// accepted an OR match, so "the moon is made of cheese" was **certified as supported
    /// by fresh evidence**: the word "the" appears in every capture ever taken. A tool
    /// whose entire purpose is catching claims that have rotted, vouching for anything at
    /// all, is the worst failure this product can have: confident, cited and wrong.
    // MARK: - Rarity, measured against this life rather than against English

    /// How many captures contain each of these terms, from the full-text index.
    ///
    /// `commonWords` is a hand-written English stopword list. It knows that "the" is common and
    /// has no idea that on this particular machine the product's own name appears in a fifth of
    /// every screen it has ever read, that "chrome" is furniture, or that the one word naming a
    /// wedding venue appears in three documents and is therefore the most discriminating token
    /// in the corpus.
    ///
    /// That is the difference between rarity in a language and rarity in a life, and it is why
    /// recall surfaced the browser and buried the venue. Berntsen's measurement of spontaneous
    /// retrieval is that a cue works when its overlap with one episode discriminates it from all
    /// the others — specificity, not strength — which is document frequency by another name.
    ///
    /// Counted through `captures_fts` rather than `fts5vocab`, which would have been the
    /// obvious choice and cannot be used here: a vocabulary table has to be CREATEd, and this
    /// connection runs under `PRAGMA query_only = ON`. That guard is the reason the MCP server
    /// provably cannot write to the memory, and it is worth more than a tidier query. Matching
    /// the index once per term is indexed, read-only, and bounded by the six terms a query
    /// keeps.
    ///
    /// Returns an empty map when there is no full-text index to ask, and every caller treats
    /// that as "no opinion" rather than as "rare".
    func documentFrequencies(for terms: [String]) -> [String: Int] {
        guard !terms.isEmpty else { return [:] }
        var out: [String: Int] = [:]
        for term in terms {
            // A quoted phrase, so punctuation and FTS operators inside a term are literal.
            let quoted = "\"" + term.replacingOccurrences(of: "\"", with: "") + "\""
            let rows = database.query(
                "SELECT COUNT(*) AS n FROM captures_fts WHERE captures_fts MATCH ?", [.text(quoted)])
            guard let n = rows.first?["n"].intValue else { return [:] }
            out[term] = Int(n)
        }
        return out
    }

    /// The query's terms, rarest in this corpus first, with the corpus-common ones dropped.
    ///
    /// Two filters, in order. The English stopword list still runs, because it is free and
    /// catches "the" without a query. Then document frequency drops anything appearing in more
    /// than ``commonInThisCorpus`` of captures — which is how a term that is not an English
    /// stopword but *is* this person's wallpaper stops steering an answer.
    ///
    /// Never returns empty when the stopword pass found something: a question made entirely of
    /// words this person uses constantly is still a question, and answering "nothing matched"
    /// because every term was too ordinary would be worse than answering it badly. In that case
    /// the ordering still applies, so the rarest of the ordinary words leads.
    func rankedTerms(in query: String) -> [String] {
        let base = MemoirMemory.distinctiveTerms(in: query)
        guard base.count > 1 else { return base }
        let frequencies = documentFrequencies(for: base)
        guard !frequencies.isEmpty else { return base }
        let total = max(1, captureCount())
        let ceiling = Int(Double(total) * MemoirMemory.commonInThisCorpus)

        let ordered = base.sorted { a, b in
            let fa = frequencies[a] ?? 0, fb = frequencies[b] ?? 0
            if fa != fb { return fa < fb }
            return a < b
        }
        let kept = ordered.filter { (frequencies[$0] ?? 0) <= ceiling }
        return kept.isEmpty ? ordered : kept
    }

    /// A term in more than this share of captures is furniture on this machine, whatever the
    /// dictionary thinks. Measured on a real vault: the product's own name reached 20.1% of
    /// captures, "architecture" 6.1%, while a ticket key central to months of work sat at 3.5%.
    /// The threshold sits above the working vocabulary and below the wallpaper.
    static let commonInThisCorpus = 0.15

    /// How many captures the memory holds, for turning a document count into a share.
    func captureCount() -> Int {
        guard let map = map(.captures) else { return 0 }
        let rows = database.query("SELECT COUNT(*) AS n FROM \"\(map.table)\"", [])
        return Int(rows.first?["n"].intValue ?? 0)
    }

    static func distinctiveTerms(in claim: String) -> [String] {
        claim
            .lowercased()
            .split(whereSeparator: { !($0.isLetter || $0.isNumber) })
            .map(String.init)
            .filter { $0.count >= 3 && !commonWords.contains($0) }
            .reduce(into: [String]()) { out, word in if !out.contains(word) { out.append(word) } }
    }

    static func terms(in query: String) -> [String] {
        query
            .split(whereSeparator: { $0.isWhitespace || $0 == "," })
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`.;:!?()[]{}")) }
            .filter { $0.count >= 2 }
            .prefix(6)
            .map { String($0) }
    }

    /// Escapes LIKE wildcards so a query containing `%` or `_` matches literally.
    static func escapeLike(_ term: String) -> String {
        term
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }
}
