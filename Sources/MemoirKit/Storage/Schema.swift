import Foundation

/// The SQL that defines Memoir's database, plus the versioned migration ladder.
///
/// Rules this file obeys:
/// - Every migration is **additive and idempotent** (`IF NOT EXISTS` everywhere), so running
///   it twice is harmless and an interrupted upgrade can be retried.
/// - Dates are REAL unix timestamps. Booleans are INTEGER 0/1. IDs are lowercase UUID TEXT.
/// - Every column that appears in a `WHERE` or `ORDER BY` in `Store` has an index.
/// - The full-text tables are created separately from the core schema (see `ftsSetup`) so
///   that a SQLite build without FTS5 degrades to `LIKE` search instead of failing to open.
enum Schema {

    /// A single step on the migration ladder.
    struct Migration {
        /// The `PRAGMA user_version` value the database has *after* this migration applies.
        let version: Int32
        /// The SQL script, executed inside one transaction.
        let sql: String
    }

    /// The schema version this build writes and understands.
    static let version: Int32 = 12

    /// The ordered migration ladder. Append new entries, never edit an applied one.
    static let migrations: [Migration] = [
        Migration(version: 1, sql: v1),
        Migration(version: 2, sql: v2),
        Migration(version: 3, sql: v3),
        Migration(version: 4, sql: v4),
        Migration(version: 5, sql: v5),
        Migration(version: 6, sql: v6),
        Migration(version: 7, sql: v7),
        Migration(version: 8, sql: v8),
        Migration(version: 9, sql: v9),
        Migration(version: 10, sql: v10),
        Migration(version: 11, sql: v11),
        Migration(version: 12, sql: v12),
    ]

    /// The part of a capture that was actually within the window's bounds.
    ///
    /// A capture is the accessibility tree, and on a virtualised feed that tree is not the
    /// screen: LinkedIn keeps a band of mounted posts around the viewport, so a capture taken
    /// while reading one post also contains the four scrolled past above it. Flattened into
    /// one blob they are indistinguishable, and "what was that post I just read" could not be
    /// answered from a memory that genuinely held the answer: the post sat 14,605 characters
    /// in, behind four others, with nothing to say which one had been on screen.
    ///
    /// Nullable on purpose, and it is not a second copy of the text. NULL means the geometry
    /// was never read: every capture taken before this column existed, and every one since
    /// where the window frame could not be resolved. That is different from an empty string,
    /// which would claim the screen was blank. Only substantial blocks are recorded (see
    /// ``CaptureLimits/visibleTextMinimum``), because the point is to find what was being
    /// read, and because the geometry costs an accessibility round trip per block.
    ///
    /// `text` is untouched by this migration and keeps its exact contents, ordering and hash,
    /// so extraction, dedupe and the full-text index carry on reading what they always did.
    /// The day a journal entry is *about*, when the user filed it under one (schema v12).
    ///
    /// Null for everything else, and that is the marker: a non-null `filed_at` means a human sat
    /// down and wrote about a day. Nothing in the schema said so before, and the cost was
    /// exact: a journal entry and a note pushed from the chat are structurally identical rows —
    /// same kind, same `.authored` source, same confidence of 1.0, same null detail — so the
    /// only way to isolate the user's own diary was the accidental pair `confidence = 1.0 AND
    /// detail IS NULL`, which is two columns lining up by coincidence and would break the first
    /// time either was reused.
    ///
    /// It also unpicks an overloading. `updated_at` means *last seen* for an inferred row and
    /// *the day this is about* for a journal entry, in the same column, and `what_happened`
    /// sorts by it. Measured on the real vault, the six journal entries ranked 20th, 149th,
    /// 15th, 53rd, 42nd and 97th inside their own days against a cap of eight. **None of the
    /// user's own words had ever reached an answer.** `updated_at` keeps its existing meaning
    /// so the calendar surfaces are untouched; this column is the one that is asked.
    ///
    /// Backfilled once from the accidental rule by ``Store/repairJournalFiling()``, which is the
    /// last time that rule is ever used.
    static let v12 = """
    ALTER TABLE entities ADD COLUMN filed_at REAL;
    CREATE INDEX IF NOT EXISTS idx_entities_filed_at ON entities(filed_at);
    """

    /// Where on the screen a piece of evidence sat. See ``EvidenceStrength``.
    ///
    /// Defaults to `direct` rather than to unknown, which is a deliberate difference from how
    /// `extractor` handled the same problem at v9. There, `0` had to mean "predates
    /// attribution", because backfilling a pass name would have asserted something false about
    /// which extractor found the row. Here the old rows are not ambiguous: every read path in
    /// the product already presented them as the screen speaking, so reading them as `direct`
    /// records what was already being claimed rather than inventing a new claim about them.
    ///
    /// The measurement that made this worth a column: across captures where the viewport was
    /// known, only about half the stored characters were inside the window. Half of what can
    /// be cited is text nobody saw.
    static let v11 = """
    ALTER TABLE provenance ADD COLUMN strength TEXT NOT NULL DEFAULT 'direct';
    CREATE INDEX IF NOT EXISTS idx_provenance_strength ON provenance(strength);
    """

    /// The calendar date a capture belongs to, decided once and written down (schema v10).
    ///
    /// Only imported rows carry it. A screen capture happens at an instant the user was
    /// present for, and `date(ts)` is the right answer for one; an imported row is different,
    /// and the difference cost this product half its photo library.
    ///
    /// A photo row does not carry an event time. `LifeImporter` renders a *local midnight*
    /// through a formatter and stores that instant, so on this machine the whole nine-year
    /// spine sits at three UTC hours — 22:00, 23:00 and 00:00 — every one of which straddles a
    /// midnight boundary. Recompute `date(ts)` under a different offset and 97% of those rows
    /// move to a different calendar day, and the total day count swings by 13.7%.
    ///
    /// Worse, the id was derived from the same rendered string, so importing under two offsets
    /// minted two rows for the same day: 2,027 of 4,350 photo rows on the developer's own vault
    /// were exact duplicates an hour apart. `Store.repairImportedDays` clears those and fills
    /// this column; `LifeImporter` writes it for every row it creates from now on.
    ///
    /// A date that was decided once and stored is stable. A date derived from a rendered
    /// timestamp is a function of whoever is reading.
    static let v10 = """
    ALTER TABLE captures ADD COLUMN local_day TEXT;
    CREATE INDEX IF NOT EXISTS idx_captures_local_day ON captures(local_day);
    """

    static let v8 = """
    ALTER TABLE captures ADD COLUMN visible_text TEXT;
    """

    /// Which pass produced a piece of evidence, so the model pass can be seen to be working.
    ///
    /// `LLMExtractor` was written, tested and documented as part of the pipeline, and was never
    /// handed to a `MemoryService` for months. Once wired it then failed on every call, its
    /// prompt overflowing the on-device context window, logging one line indistinguishable from
    /// a quiet day. Nothing measured whether the model pass contributed anything, so nothing
    /// could tell working from dead.
    ///
    /// **On provenance, not entities.** `RuleExtractor` runs first at both wiring sites, and the
    /// merge laws keep the receiver: `ExtractionResult.merging` never discards what it already
    /// found, and `MemoryMerge.merged` starts from the existing row. So an entity-level column
    /// would read "rule" for every entity both passes found, and credit the model only where the
    /// rules found nothing. On a corpus where the rules are good, a model corroborating
    /// constantly and originating rarely would count as zero: the same silent zero this exists
    /// to kill. Evidence is the level at which both passes can be true at once.
    ///
    /// **Default 0 means "predates attribution", not "rules".** Backfilling 1 would be a lie on
    /// any database that has been through `memoir-ask --reindex`, which has wired the model pass
    /// since before this column existed. One extra state to explain beats a number that asserts
    /// something false.
    static let v9 = """
    ALTER TABLE provenance ADD COLUMN extractor INTEGER NOT NULL DEFAULT 0;
    """

    /// Marks a commitment Memoir cannot show it was *yours*.
    ///
    /// A browser shows you other people's first-person sentences all day: a tweet, a
    /// LinkedIn reply, an AI-drafted email, your own marketing copy. By text alone none of
    /// those is distinguishable from a promise you made, and measured on a real database
    /// 17 of 25 stored commitments were somebody else's words read off a web page.
    ///
    /// Kept rather than dropped, because the text is real and the user may want it; never
    /// surfaced, because asserting it is the failure. Reading is not writing.
    static let v7 = """
    ALTER TABLE entities ADD COLUMN provisional INTEGER NOT NULL DEFAULT 0;
    CREATE INDEX IF NOT EXISTS idx_entities_provisional ON entities(provisional);
    """

    /// Alternate names an entity also goes by, for the ontology matcher.
    ///
    /// `source` is deliberately NOT here: it arrived at v3 on this line of development,
    /// and re-adding it would fail on every database that has already migrated. This
    /// step adds only what is genuinely new. `ALTER TABLE ADD COLUMN` has no
    /// `IF NOT EXISTS`; idempotency is the ladder's transaction + `user_version` bump.
    static let v6 = """
    ALTER TABLE entities ADD COLUMN aliases TEXT NOT NULL DEFAULT '[]';
    """


    /// Visible completion for the todo list (the notch band's Todos pane).
    ///
    /// `completed_at` makes "done" a shown, reversible, queryable state (struck
    /// through with a time, reopenable) where the soft delete stays the state for
    /// "gone from every list". Both are permanent against extraction. `ALTER TABLE
    /// ADD COLUMN` has no `IF NOT EXISTS`; this step's idempotency is the ladder's
    /// transaction + `user_version` bump, like v3's.
    static let v5 = """
    ALTER TABLE entities ADD COLUMN completed_at REAL;
    CREATE INDEX IF NOT EXISTS idx_entities_completed_at ON entities(completed_at);
    CREATE INDEX IF NOT EXISTS idx_entities_kind_due ON entities(kind, deleted, completed_at, due_at);
    """

    /// Adds semantic vectors so recall can match meaning, not just literal words.
    ///
    /// Kept in its own table rather than a column on `captures`: vectors are ~2 KB each and
    /// would otherwise be read on every ordinary capture query for no reason. A NULL vector
    /// means "not embedded yet"; an empty blob means "tried and could not", which stops an
    /// unembeddable capture being retried on every backfill.
    static let v2 = """
    CREATE TABLE IF NOT EXISTS capture_embeddings (
        capture_id TEXT PRIMARY KEY NOT NULL
            REFERENCES captures(id) ON DELETE CASCADE,
        vector     BLOB NOT NULL,
        dimension  INTEGER NOT NULL
    );
    CREATE INDEX IF NOT EXISTS idx_embeddings_capture ON capture_embeddings(capture_id);
    """

    /// Records whether the user authored an entity or Memoir inferred it.
    ///
    /// The distinction the whole PUSH feature rests on. Everything before this was guessed
    /// from screen text, and every extraction bug in this project came from that guessing.
    /// Something the user typed is clean by construction, so it must be protected from
    /// everything that is not.
    ///
    /// Two SQLite facts shape this migration:
    ///
    /// 1. `ALTER TABLE ... ADD COLUMN` has no `IF NOT EXISTS`, so this is the one step that
    ///    cannot literally honour the idempotency rule at the top of this file. It is still
    ///    safe: `Store.migrate` runs each step inside `BEGIN IMMEDIATE` together with the
    ///    `PRAGMA user_version` bump, so a crash rolls the whole step back and it replays
    ///    from a clean state.
    /// 2. A `NOT NULL` column added to a populated table REQUIRES a non-null default. That
    ///    default IS the backfill: every row that existed before PUSH reads as `inferred`,
    ///    which is exactly what it is.
    static let v3 = """
    ALTER TABLE entities ADD COLUMN source TEXT NOT NULL DEFAULT 'inferred';
    CREATE INDEX IF NOT EXISTS idx_entities_source ON entities(source);
    """

    /// Persists the PASSAGE vectors, which until now were recomputed on every single search.
    ///
    /// ``SemanticIndex/search(_:limit:minimumScore:)`` re-scores its shortlist passage by
    /// passage, because a whole-capture vector averages a long page's meaning away. Whole
    /// captures were embedded once and kept in `capture_embeddings`; their passages were not,
    /// so every search re-embedded up to 12 passages for each of 72 candidates at ~4ms a
    /// passage. Measured on the real 482-vector corpus, release build: "what was that repo
    /// about screen memory" spent **3665ms** there and "the tweet about claude skills wrapped
    /// in an sms app" **7849ms**, out of a 24s answer. With this table the same two searches
    /// take **6ms** and **9ms**, and return the identical twelve captures with identical
    /// scores to six decimal places.
    ///
    /// One row per capture, all of its passage vectors packed end to end in a single blob,
    /// rather than a row per passage. A search wants every passage of a candidate or none of
    /// them, so a row per passage would buy nothing and cost ~9x the row overhead plus a
    /// sort. `count` and `dimension` are what make the blob decodable; `count = 0` with an
    /// empty blob means "attempted, nothing embeddable", the same convention
    /// `capture_embeddings` uses to stop retrying a capture forever.
    ///
    /// Cost measured on the real corpus: **8.2 MB** for 482 embeddable captures (4191
    /// passages, 17.4 KB per capture, 512 floats each). That is 8x what the whole-capture
    /// vectors cost, and it is what buys the 400x on the search. Only captures that a search
    /// actually shortlists, or that `memoir-ask --embed` sweeps, get a row here, so the real
    /// figure trails the corpus. `ON DELETE CASCADE` means retention frees these exactly as
    /// it frees the captures, so this grows with the retention window and not with time. At
    /// the 60-day figure quoted in ``SemanticIndex`` a fully swept database would be ~400 MB,
    /// which is the number to watch if retention is ever raised.
    static let v4 = """
    CREATE TABLE IF NOT EXISTS capture_passage_vectors (
        capture_id TEXT PRIMARY KEY NOT NULL
            REFERENCES captures(id) ON DELETE CASCADE,
        vectors    BLOB NOT NULL,
        dimension  INTEGER NOT NULL,
        count      INTEGER NOT NULL
    );
    CREATE INDEX IF NOT EXISTS idx_passage_vectors_capture ON capture_passage_vectors(capture_id);
    """

    // MARK: - Column lists
    //
    // Named constants so that decoding indices in `Store` can never drift from the SELECT.

    static let captureColumns = "id, ts, app_bundle_id, app_name, window_title, text, text_hash, visible_text, local_day"
    static let entityColumns = """
    id, kind, title, detail, due_at, confidence, pinned, corrected, deleted, created_at, updated_at, source, completed_at, aliases, provisional, filed_at
    """
    static let provenanceColumns = "id, entity_id, capture_id, field, snippet, ts, extractor, strength"
    static let sessionColumns = "id, app_bundle_id, app_name, started_at, ended_at, idle"

    // MARK: - Version 1

    /// Version 1: the whole core schema.
    ///
    /// Note on foreign keys: `provenance.entity_id` references `entities(id)` with
    /// `ON DELETE CASCADE`, because provenance for an entity that no longer exists is
    /// meaningless. `provenance.capture_id` deliberately has **no** foreign key: captures
    /// roll off on a retention schedule while entities persist forever, and the stored
    /// `snippet` keeps the entity traceable after its source capture is gone. A foreign key
    /// there would either block retention or cascade away the audit trail.
    private static let v1 = """
    CREATE TABLE IF NOT EXISTS captures (
        id             TEXT PRIMARY KEY NOT NULL,
        ts             REAL NOT NULL,
        app_bundle_id  TEXT NOT NULL,
        app_name       TEXT NOT NULL,
        window_title   TEXT,
        text           TEXT NOT NULL,
        text_hash      TEXT NOT NULL
    );
    CREATE INDEX IF NOT EXISTS idx_captures_ts ON captures(ts);
    CREATE INDEX IF NOT EXISTS idx_captures_text_hash ON captures(text_hash);
    CREATE INDEX IF NOT EXISTS idx_captures_bundle ON captures(app_bundle_id);
    CREATE INDEX IF NOT EXISTS idx_captures_bundle_ts ON captures(app_bundle_id, ts);

    CREATE TABLE IF NOT EXISTS entities (
        id          TEXT PRIMARY KEY NOT NULL,
        kind        TEXT NOT NULL,
        title       TEXT NOT NULL,
        detail      TEXT,
        due_at      REAL,
        confidence  REAL NOT NULL DEFAULT 0.5,
        pinned      INTEGER NOT NULL DEFAULT 0,
        corrected   INTEGER NOT NULL DEFAULT 0,
        deleted     INTEGER NOT NULL DEFAULT 0,
        created_at  REAL NOT NULL,
        updated_at  REAL NOT NULL
    );
    CREATE INDEX IF NOT EXISTS idx_entities_kind ON entities(kind);
    CREATE INDEX IF NOT EXISTS idx_entities_deleted ON entities(deleted);
    CREATE INDEX IF NOT EXISTS idx_entities_kind_deleted ON entities(kind, deleted);
    CREATE INDEX IF NOT EXISTS idx_entities_due_at ON entities(due_at);
    CREATE INDEX IF NOT EXISTS idx_entities_updated_at ON entities(updated_at);
    CREATE INDEX IF NOT EXISTS idx_entities_created_at ON entities(created_at);
    CREATE INDEX IF NOT EXISTS idx_entities_pinned ON entities(pinned);
    CREATE INDEX IF NOT EXISTS idx_entities_title ON entities(title);

    CREATE TABLE IF NOT EXISTS provenance (
        id         TEXT PRIMARY KEY NOT NULL,
        entity_id  TEXT NOT NULL REFERENCES entities(id) ON DELETE CASCADE,
        capture_id TEXT NOT NULL,
        field      TEXT NOT NULL,
        snippet    TEXT NOT NULL,
        ts         REAL NOT NULL,
        extractor  INTEGER NOT NULL DEFAULT 0
    );
    CREATE INDEX IF NOT EXISTS idx_provenance_entity ON provenance(entity_id);
    CREATE INDEX IF NOT EXISTS idx_provenance_capture ON provenance(capture_id);
    CREATE INDEX IF NOT EXISTS idx_provenance_ts ON provenance(ts);

    CREATE TABLE IF NOT EXISTS sessions (
        id            TEXT PRIMARY KEY NOT NULL,
        app_bundle_id TEXT NOT NULL,
        app_name      TEXT NOT NULL,
        started_at    REAL NOT NULL,
        ended_at      REAL NOT NULL,
        idle          INTEGER NOT NULL DEFAULT 0
    );
    CREATE INDEX IF NOT EXISTS idx_sessions_started_at ON sessions(started_at);
    CREATE INDEX IF NOT EXISTS idx_sessions_ended_at ON sessions(ended_at);
    CREATE INDEX IF NOT EXISTS idx_sessions_bundle ON sessions(app_bundle_id);
    CREATE INDEX IF NOT EXISTS idx_sessions_idle ON sessions(idle);
    """

    // MARK: - Full text search

    /// The FTS5 virtual tables and the triggers that keep them in sync.
    ///
    /// Both tables are *external content* tables (`content='captures'` /
    /// `content='entities'`): the index stores only the inverted index, the rows themselves
    /// stay in the base table. That halves the on-disk cost and makes the base table the
    /// single source of truth. The `AFTER INSERT/DELETE/UPDATE` triggers are what keep the
    /// index honest, including for `INSERT OR REPLACE` (which fires delete + insert).
    static let ftsSetup = """
    CREATE VIRTUAL TABLE IF NOT EXISTS captures_fts USING fts5(
        text,
        content='captures',
        content_rowid='rowid',
        tokenize='unicode61 remove_diacritics 2'
    );

    CREATE TRIGGER IF NOT EXISTS captures_fts_ai AFTER INSERT ON captures BEGIN
        INSERT INTO captures_fts(rowid, text) VALUES (new.rowid, new.text);
    END;
    CREATE TRIGGER IF NOT EXISTS captures_fts_ad AFTER DELETE ON captures BEGIN
        INSERT INTO captures_fts(captures_fts, rowid, text) VALUES ('delete', old.rowid, old.text);
    END;
    CREATE TRIGGER IF NOT EXISTS captures_fts_au AFTER UPDATE ON captures BEGIN
        INSERT INTO captures_fts(captures_fts, rowid, text) VALUES ('delete', old.rowid, old.text);
        INSERT INTO captures_fts(rowid, text) VALUES (new.rowid, new.text);
    END;

    CREATE VIRTUAL TABLE IF NOT EXISTS entities_fts USING fts5(
        title,
        detail,
        content='entities',
        content_rowid='rowid',
        tokenize='unicode61 remove_diacritics 2'
    );

    CREATE TRIGGER IF NOT EXISTS entities_fts_ai AFTER INSERT ON entities BEGIN
        INSERT INTO entities_fts(rowid, title, detail) VALUES (new.rowid, new.title, new.detail);
    END;
    CREATE TRIGGER IF NOT EXISTS entities_fts_ad AFTER DELETE ON entities BEGIN
        INSERT INTO entities_fts(entities_fts, rowid, title, detail)
        VALUES ('delete', old.rowid, old.title, old.detail);
    END;
    CREATE TRIGGER IF NOT EXISTS entities_fts_au AFTER UPDATE ON entities BEGIN
        INSERT INTO entities_fts(entities_fts, rowid, title, detail)
        VALUES ('delete', old.rowid, old.title, old.detail);
        INSERT INTO entities_fts(rowid, title, detail) VALUES (new.rowid, new.title, new.detail);
    END;
    """

    /// Rebuilds both full-text indexes from the base tables. Cheap on an empty database,
    /// and the correct repair when the index is created over pre-existing rows.
    static let ftsRebuild = """
    INSERT INTO captures_fts(captures_fts) VALUES ('rebuild');
    INSERT INTO entities_fts(entities_fts) VALUES ('rebuild');
    """

    /// Empties both full-text indexes. Used by `purgeEverything`.
    static let ftsDeleteAll = """
    INSERT INTO captures_fts(captures_fts) VALUES ('delete-all');
    INSERT INTO entities_fts(entities_fts) VALUES ('delete-all');
    """
}
