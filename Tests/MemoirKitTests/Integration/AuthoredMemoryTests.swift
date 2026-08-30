import Foundation
import SQLite3
import Testing
import MemoirFixtures
@testable import MemoirKit

// Tier 5: authored memory. Everything the user wrote themselves is clean by
// construction and must be protected from everything that guesses.
//
// CF-54: authored beats inferred, always. CF-1 extended from correction to creation.
// CF-55: authored entities are visibly distinct, and the flag survives round trips.
//
// Same rules as every integration flow: TestWorkspace for isolation, TestClock for
// time, TestID for ids, no network, no wall clock.

@Suite("CF-54 authored beats inferred")
struct AuthoredBeatsInferredTests {

    /// An authored entity, as the vault importer or an accepted proposal would write it.
    private func authoredProject(at date: Date) -> Entity {
        Entity(
            id: TestID.stable("entity", "project", "Fenwick Migration"),
            kind: .project,
            title: "Fenwick Migration",
            detail: "Move billing off the legacy Fenwick stack.",
            confidence: 0.9,
            source: .authored,
            aliases: ["fenwick", "FEN-42"],
            createdAt: date,
            updatedAt: date
        )
    }

    @Test("CF-54 repeated extraction never overwrites an authored entity")
    func authoredSurvivesExtraction() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            let memory = MemoryService(store: store, extractors: [RuleExtractor()])
            let t0 = TestClock.reference

            try await store.upsert(entity: authoredProject(at: t0))

            // Three passes of colliding inferred candidates, confidence rising each time.
            for round in 0..<3 {
                let capture = Fixtures.capture(
                    text: "Fenwick Migration standup: blocked on the rate limiter again.",
                    app: "Slack",
                    bundleID: "com.tinyspeck.slackmacgap",
                    windowTitle: "#fenwick (Slack)",
                    at: TestClock.minutes(Double(round + 1)),
                    name: "fenwick-standup-\(round)"
                )
                try await store.insert(capture: capture)
                let candidate = Entity(
                    id: TestID.stable("entity", "project", "candidate", String(round)),
                    kind: .project,
                    title: "Fenwick Migration",
                    detail: "an on-screen guess that must never land",
                    confidence: 0.7 + Double(round) * 0.1,
                    source: .inferred,
                    createdAt: TestClock.minutes(Double(round + 1)),
                    updatedAt: TestClock.minutes(Double(round + 1))
                )
                let result = ExtractionResult(
                    entities: [candidate],
                    provenance: [makeProvenance(
                        entityID: candidate.id,
                        captureID: capture.id,
                        snippet: "Fenwick Migration standup",
                        at: TestClock.minutes(Double(round + 1))
                    )]
                )
                _ = try await memory.commit(result, now: TestClock.minutes(Double(round + 1)))
            }

            let stored = try #require(
                try await store.entity(id: TestID.stable("entity", "project", "Fenwick Migration"))
            )
            #expect(stored.title == "Fenwick Migration")
            #expect(stored.detail == "Move billing off the legacy Fenwick stack.")
            #expect(stored.source == .authored, "source may never degrade to inferred")
            #expect(stored.confidence >= 0.9, "confidence may rise; nothing else moves")

            // No duplicate inferred twin was created beside it.
            let projects = try await store.entities(kind: .project, includeDeleted: false)
            #expect(projects.count == 1)
        }
    }

    @Test("CF-54 an inferred candidate matching an alias corroborates, not duplicates")
    func aliasAbsorbsInferredCandidate() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            let memory = MemoryService(store: store, extractors: [RuleExtractor()])
            try await store.upsert(entity: authoredProject(at: TestClock.reference))

            let capture = Fixtures.capture(
                text: "fenwick: deploy blocked until Thursday",
                app: "Slack",
                bundleID: "com.tinyspeck.slackmacgap",
                windowTitle: "#deploys (Slack)",
                at: TestClock.minutes(5),
                name: "fenwick-alias-sighting"
            )
            try await store.insert(capture: capture)
            // The extractor saw the alias, not the canonical name.
            let candidate = Entity(
                id: TestID.stable("entity", "project", "fenwick"),
                kind: .project,
                title: "fenwick",
                confidence: 0.6,
                source: .inferred,
                createdAt: TestClock.minutes(5),
                updatedAt: TestClock.minutes(5)
            )
            let result = ExtractionResult(
                entities: [candidate],
                provenance: [makeProvenance(
                    entityID: candidate.id,
                    captureID: capture.id,
                    snippet: "fenwick: deploy blocked",
                    at: TestClock.minutes(5)
                )]
            )
            _ = try await memory.commit(result, now: TestClock.minutes(5))

            let projects = try await store.entities(kind: .project, includeDeleted: false)
            #expect(projects.count == 1, "the alias hit must merge, not mint a twin")
            #expect(projects.first?.title == "Fenwick Migration")
            #expect(projects.first?.source == .authored)

            // The provenance row landed on the authored entity: the sighting is recorded
            // as evidence for the real project.
            let evidence = try await store.provenance(
                entityID: TestID.stable("entity", "project", "Fenwick Migration")
            )
            #expect(evidence.contains { $0.captureID == capture.id })
        }
    }

    @Test("CF-54 an authored arrival adopts the existing inferred guess")
    func authoredAdoptsInferred() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            let memory = MemoryService(store: store, extractors: [RuleExtractor()])

            // The guess got there first, with a capture and provenance behind it.
            let capture = Fixtures.capture(
                text: "fenwick migration kickoff notes",
                app: "Notes",
                bundleID: "com.apple.Notes",
                windowTitle: "fenwick migration",
                at: TestClock.reference,
                name: "fenwick-kickoff"
            )
            try await store.insert(capture: capture)
            let guess = Entity(
                id: TestID.stable("entity", "project", "fenwick migration"),
                kind: .project,
                title: "fenwick migration",
                confidence: 0.5,
                source: .inferred,
                createdAt: TestClock.reference,
                updatedAt: TestClock.reference
            )
            try await store.upsert(entity: guess)
            try await store.add(provenance: makeProvenance(
                entityID: guess.id,
                captureID: capture.id,
                snippet: "fenwick migration kickoff"
            ))

            // Then the vault says what it actually is.
            let authored = authoredProject(at: TestClock.minutes(10))
            _ = try await memory.commit(
                ExtractionResult(entities: [authored], provenance: []),
                now: TestClock.minutes(10)
            )

            let projects = try await store.entities(kind: .project, includeDeleted: false)
            #expect(projects.count == 1, "adoption, not a second row")
            let adopted = try #require(projects.first)
            #expect(adopted.id == guess.id, "identity survives so provenance stays attached")
            #expect(adopted.title == "Fenwick Migration", "the user's words replace the guess")
            #expect(adopted.source == .authored)

            let evidence = try await store.provenance(entityID: guess.id)
            #expect(!evidence.isEmpty, "the old evidence still belongs to the adopted entity")
        }
    }
}

@Suite("CF-55 authored entities are visibly distinct")
struct AuthoredVisibilityTests {

    @Test("CF-55 the source flag survives the store and consolidation")
    func sourceFlagRoundTrips() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            let authored = Entity(
                id: TestID.stable("entity", "note", "Wifi password is on the fridge"),
                kind: .note,
                title: "Wifi password is on the fridge",
                source: .authored,
                aliases: ["wifi"],
                createdAt: TestClock.reference,
                updatedAt: TestClock.reference
            )
            let inferred = makeEntity(kind: .note, title: "standup moved to 10")
            try await seed(store: store, entities: [authored, inferred])

            let listed = try await store.entities(kind: .note, includeDeleted: false)
            #expect(listed.count == 2)
            let byTitle = Dictionary(uniqueKeysWithValues: listed.map { ($0.title, $0) })
            #expect(byTitle["Wifi password is on the fridge"]?.source == .authored)
            #expect(byTitle["Wifi password is on the fridge"]?.aliases == ["wifi"])
            #expect(byTitle["standup moved to 10"]?.source == .inferred)

            // Consolidating over unrelated captures must not disturb either flag.
            let memory = MemoryService(store: store, extractors: [RuleExtractor()])
            try await store.insert(capture: Fixtures.slackThread(at: TestClock.minutes(1)))
            _ = try await memory.consolidate(since: TestClock.reference, now: TestClock.minutes(2))

            let after = try await store.entities(kind: .note, includeDeleted: false)
            let afterByTitle = Dictionary(uniqueKeysWithValues: after.map { ($0.title, $0) })
            #expect(afterByTitle["Wifi password is on the fridge"]?.source == .authored)
            #expect(afterByTitle["standup moved to 10"]?.source == .inferred)
        }
    }

    /// A pre-`source` database upgraded by the app reads every old row as inferred, and
    /// the columns added since (`source`, `completed_at`, `aliases`) arrive with their
    /// defaults. Opened with `mayMigrate: true` because that is the app's consent to
    /// reshape an existing memory; a tool opening the same file must be refused, which
    /// is asserted separately below.
    @Test("CF-55 a v2 database migrates: every pre-existing row reads as inferred")
    func v2RowsMigrateAsInferred() async throws {
        try await TestWorkspace.with { ws in
            // Hand-build a version-2 database: core schema + embeddings, no source column.
            var handle: OpaquePointer?
            #expect(sqlite3_open(ws.dbURL.path, &handle) == SQLITE_OK)
            let db = try #require(handle)
            let legacyEntities = """
            CREATE TABLE entities (
                id TEXT PRIMARY KEY NOT NULL, kind TEXT NOT NULL, title TEXT NOT NULL,
                detail TEXT, due_at REAL, confidence REAL NOT NULL DEFAULT 0.5,
                pinned INTEGER NOT NULL DEFAULT 0, corrected INTEGER NOT NULL DEFAULT 0,
                deleted INTEGER NOT NULL DEFAULT 0, created_at REAL NOT NULL, updated_at REAL NOT NULL
            );
            -- v1's captures table, as any real v2 database has it. Without it this fixture
            -- is a v2 that never ran v1, and a later migration that touches captures (v8
            -- adds visible_text) fails against a shape no user could be on.
            CREATE TABLE captures (
                id TEXT PRIMARY KEY NOT NULL, ts REAL NOT NULL, app_bundle_id TEXT NOT NULL,
                app_name TEXT NOT NULL, window_title TEXT, text TEXT NOT NULL, text_hash TEXT NOT NULL
            );
            -- v1's provenance table, for the same reason as captures above: v9 adds
            -- `extractor` to it, and a fixture that never ran v1 has no provenance table for
            -- the ALTER to land on. Pre-v9 shape, so the migration is genuinely exercised.
            CREATE TABLE provenance (
                id TEXT PRIMARY KEY NOT NULL,
                entity_id TEXT NOT NULL REFERENCES entities(id) ON DELETE CASCADE,
                capture_id TEXT NOT NULL, field TEXT NOT NULL, snippet TEXT NOT NULL,
                ts REAL NOT NULL
            );
            INSERT INTO entities VALUES (
                'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee', 'project', 'Legacy row', NULL, NULL,
                0.5, 0, 0, 0, 1700000000, 1700000000
            );
            PRAGMA user_version = 2;
            """
            #expect(sqlite3_exec(db, legacyEntities, nil, nil, nil) == SQLITE_OK)
            sqlite3_close_v2(db)

            // The app's consent to reshape an existing memory. What matters is that the
            // ladder applies over a real v2 entities table and old rows still load.
            let store = try Store(path: ws.dbURL, mayMigrate: true)
            let migrated = try #require(
                try await store.entity(id: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")
            )
            #expect(migrated.source == .inferred, "nothing authored existed before v3")
            #expect(migrated.aliases.isEmpty)
            #expect(migrated.title == "Legacy row")
        }
    }
}
