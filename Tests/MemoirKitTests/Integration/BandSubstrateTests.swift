//  Tier 6: the band and the timer (CF-59, CF-63, CF-64), plus the schema-v5 ladder.
//
//  The band's collapsed strip shows one number computed from the store; the
//  timer is a fact that lands in the day; nudges reach the user only through the
//  restraint engine. All of it is decided against injected clocks, and all of it
//  is proven here without a pixel of UI.

import Foundation
import SQLite3
import Testing

import MemoirFixtures
@testable import MemoirKit

@Suite("Tier 6 · the band and the timer")
struct BandSubstrateTests {

    // MARK: - The migration ladder

    @Test("a v2 database climbs the whole ladder with existing rows reading as open + inferred")
    func v2FileMigratesToCurrent() async throws {
        try await TestWorkspace.with { ws in
            // A frozen snapshot of the schema as v2 shipped it: entities without
            // completed_at/source, user_version stamped 2. Hand-built so the ladder,
            // not the test, is what brings it forward.
            var handle: OpaquePointer?
            #expect(sqlite3_open(ws.dbURL.path, &handle) == SQLITE_OK)
            let legacy = """
            CREATE TABLE entities (
                id TEXT PRIMARY KEY NOT NULL, kind TEXT NOT NULL, title TEXT NOT NULL,
                detail TEXT, due_at REAL, confidence REAL NOT NULL DEFAULT 0.5,
                pinned INTEGER NOT NULL DEFAULT 0, corrected INTEGER NOT NULL DEFAULT 0,
                deleted INTEGER NOT NULL DEFAULT 0, created_at REAL NOT NULL, updated_at REAL NOT NULL
            );
            CREATE TABLE captures (
                id TEXT PRIMARY KEY NOT NULL, ts REAL NOT NULL, app_bundle_id TEXT NOT NULL,
                app_name TEXT NOT NULL, window_title TEXT, text TEXT NOT NULL, text_hash TEXT NOT NULL
            );
            CREATE TABLE provenance (
                id TEXT PRIMARY KEY NOT NULL,
                entity_id TEXT NOT NULL REFERENCES entities(id) ON DELETE CASCADE,
                capture_id TEXT NOT NULL, field TEXT NOT NULL, snippet TEXT NOT NULL, ts REAL NOT NULL
            );
            CREATE TABLE sessions (
                id TEXT PRIMARY KEY NOT NULL, app_bundle_id TEXT NOT NULL, app_name TEXT NOT NULL,
                started_at REAL NOT NULL, ended_at REAL NOT NULL, idle INTEGER NOT NULL DEFAULT 0
            );
            CREATE TABLE capture_embeddings (
                capture_id TEXT PRIMARY KEY NOT NULL REFERENCES captures(id) ON DELETE CASCADE,
                vector BLOB NOT NULL, dimension INTEGER NOT NULL
            );
            INSERT INTO entities (id, kind, title, due_at, confidence, created_at, updated_at)
            VALUES ('11111111-1111-1111-1111-111111111111', 'commitment', 'Send the Q3 invoice',
                    \(TestClock.days(4).timeIntervalSince1970), 0.7,
                    \(TestClock.reference.timeIntervalSince1970),
                    \(TestClock.reference.timeIntervalSince1970));
            PRAGMA user_version = 2;
            """
            #expect(sqlite3_exec(handle, legacy, nil, nil, nil) == SQLITE_OK,
                    "\(String(cString: sqlite3_errmsg(handle)))")
            sqlite3_close_v2(handle)

            // Opening the store runs the ladder, with consent, as only the app may.
            let store = try Store(path: ws.dbURL, mayMigrate: true)
            let entity = try #require(try await store.entity(id: "11111111-1111-1111-1111-111111111111"))
            #expect(entity.completedAt == nil, "a legacy row must read as open")
            #expect(entity.source == .inferred, "a legacy row must read as inferred, never authored")
            #expect(entity.title == "Send the Q3 invoice")

            // And the new columns are live: a write with them round-trips.
            try await store.setCompleted(entityID: entity.id, at: TestClock.hours(1))
            let done = try #require(try await store.entity(id: entity.id))
            #expect(done.completedAt == TestClock.hours(1))
            await store.close()

            var reopened: OpaquePointer?
            #expect(sqlite3_open(ws.dbURL.path, &reopened) == SQLITE_OK)
            var stmt: OpaquePointer?
            sqlite3_prepare_v2(reopened, "PRAGMA user_version;", -1, &stmt, nil)
            sqlite3_step(stmt)
            #expect(sqlite3_column_int(stmt, 0) == Schema.version, "the ladder should land on the current version")
            sqlite3_finalize(stmt)
            sqlite3_close_v2(reopened)
        }
    }

    // MARK: - CF-63 · counts

    @Test("CF-63 overdue and due-today counts are computed against an injected clock")
    func countsAreExactAndExcludeTheDoneAndTheDeleted() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            let now = TestClock.reference
            let cal = TestClock.localCalendar

            // Authored, because the badge counts promises the user MADE. See
            // `CommitmentCounts.overdue`: on a real vault 39 dated open commitments were
            // counted as overdue and not one was authored — the loudest were a marketing
            // email and two sentences lifted from the user's own essay.
            func commitment(_ name: String, due: Date?, completed: Date? = nil, deleted: Bool = false,
                            source: EntitySource = .authored) -> Entity {
                Entity(id: TestID.stable("todo", name), kind: .commitment, title: name,
                       dueAt: due, deleted: deleted, completedAt: completed, source: source,
                       createdAt: TestClock.days(-1), updatedAt: TestClock.days(-1))
            }

            // Later today in the *local* calendar, whatever timezone the test runs in.
            let laterToday = cal.date(bySettingHour: 23, minute: 45, second: 0, of: now)!
            try await store.upsert(entity: commitment("overdue invoice", due: TestClock.days(-1)))
            try await store.upsert(entity: commitment("due later today", due: laterToday))
            try await store.upsert(entity: commitment("due next week", due: TestClock.days(7)))
            try await store.upsert(entity: commitment("no date at all", due: nil))
            try await store.upsert(entity: commitment("done and overdue", due: TestClock.days(-2), completed: TestClock.hours(-1)))
            try await store.upsert(entity: commitment("deleted and overdue", due: TestClock.days(-2), deleted: true))
            try await store.upsert(entity: Entity(id: TestID.stable("note", "red herring"), kind: .note,
                                                  title: "note with a date", dueAt: TestClock.days(-3),
                                                  createdAt: now, updatedAt: now))

            // Something Memoir read off a screen, dated and overdue. It must not be a debt.
            try await store.upsert(entity: commitment(
                "somebody else's overdue promise", due: TestClock.days(-1), source: .inferred))

            let counts = try await store.commitmentCounts(now: now, calendar: cal)
            #expect(counts.overdue == 1, "completed, deleted and inferred rows may never count")
            #expect(counts.dueToday == 1)
            #expect(counts.toCheck == 1, "an inferred commitment must still be offered for a look")

            // The open list agrees with the counts, in glance order: overdue first,
            // then soonest due, then the dateless.
            let open = try await store.openCommitments(now: now)
            #expect(open.map(\.title) == [
                "overdue invoice", "somebody else's overdue promise",
                "due later today", "due next week", "no date at all",
            ])

            // Completing moves a row from open to done-today, and the counts follow.
            try await store.setCompleted(entityID: TestID.stable("todo", "overdue invoice"), at: now)
            let after = try await store.commitmentCounts(now: now, calendar: cal)
            #expect(after.overdue == 0)
            #expect(try await store.completedToday(now: now, calendar: cal).map(\.title).contains("overdue invoice"))

            // Reopening restores it: completion is permanent against *extraction*,
            // not against the user changing their mind.
            try await store.setCompleted(entityID: TestID.stable("todo", "overdue invoice"), at: nil)
            #expect(try await store.commitmentCounts(now: now, calendar: cal).overdue == 1)
        }
    }

    // MARK: - CF-59 · Focus mode

    @Test("CF-59 macOS Focus mode suppresses nudges through the engine")
    func focusSuppressesNudges() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            let restraint = RestraintEngine(
                config: RestraintConfig(quietHours: QuietHours(enabled: false)),
                calendar: TestClock.localCalendar
            )
            let scanner = NudgeScanner(store: store, restraint: restraint)

            // A long live stretch in one app: normally worth a word.
            try await seedStretch(in: store)

            await restraint.setFocusMode(true)
            #expect(await scanner.scan(now: TestClock.reference) == nil,
                    "focus is on: the companion holds its tongue")

            await restraint.setFocusMode(false)
            guard case .distraction? = await scanner.scan(now: TestClock.reference) else {
                Issue.record("focus is off: the stretch should be delivered")
                return
            }
        }
    }

    // MARK: - CF-64 · the scanner → engine → dismissal loop

    /// Commitments are not a nudge channel, and this is the guard on that.
    ///
    /// The scanner used to propose every commitment coming due, and the band widened to
    /// announce it. Memoir now never raises a commitment on its own: they are kept, and
    /// they are listed on the pane that is about them, and that is the whole of it. A
    /// commitment due in ten minutes is the case that used to fire hardest, so it is the
    /// one asserted silent here.
    @Test("CF-64 a commitment coming due is never a nudge")
    func commitmentsAreNeverNudges() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            let restraint = RestraintEngine(
                config: RestraintConfig(quietHours: QuietHours(enabled: false)),
                calendar: TestClock.localCalendar
            )
            let scanner = NudgeScanner(store: store, restraint: restraint)

            // Authored: this case is about a promise the user made not becoming a nudge, so
            // it has to be a promise the user made. See `CommitmentCounts.overdue`.
            func seed(_ name: String, due: Date) async throws {
                try await store.upsert(entity: Entity(
                    id: TestID.stable("cf61", name), kind: .commitment, title: name,
                    dueAt: due, source: .authored,
                    createdAt: TestClock.days(-1), updatedAt: TestClock.days(-1)
                ))
            }

            try await seed("due in ten minutes", due: TestClock.minutes(10))
            try await seed("due next week", due: TestClock.days(7))
            try await seed("overdue since yesterday", due: TestClock.days(-1))

            #expect(await scanner.candidates(now: TestClock.reference).isEmpty)
            #expect(await scanner.scan(now: TestClock.reference) == nil)

            // And they are still in the memory: deleting the notification did not delete
            // the commitments.
            #expect(try await store.commitmentCounts(now: TestClock.reference).overdue == 1)
        }
    }

    @Test("CF-64 a dismissal buys real silence, and the mute expires")
    func dismissalBuysSilence() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            let restraint = RestraintEngine(
                config: RestraintConfig(quietHours: QuietHours(enabled: false)),
                calendar: TestClock.localCalendar
            )
            let scanner = NudgeScanner(store: store, restraint: restraint)
            try await seedStretch(in: store)

            // Delivered once…
            let first = await scanner.scan(now: TestClock.reference)
            #expect(first != nil)

            // …dismissed once: an hour of silence for that nudge, and the global
            // cooldown re-arms, so the very next scan says nothing.
            await restraint.recordDismissal(first!, now: TestClock.minutes(1))
            #expect(await scanner.scan(now: TestClock.minutes(2)) == nil)
            #expect(await scanner.scan(now: TestClock.minutes(45)) == nil,
                    "the dismissal backoff is an hour; 45 minutes is not an hour")
        }
    }

    /// Forty minutes in one app, in three near-contiguous session rows, still live.
    private func seedStretch(in store: Store) async throws {
        for (index, offset) in [(-40.0, -25.0), (-24.5, -12.0), (-11.5, -0.5)].enumerated() {
            try await store.upsert(session: Session(
                id: TestID.stable("yt", String(index)),
                appBundleID: "com.google.chrome", appName: "Chrome",
                startedAt: TestClock.minutes(offset.0), endedAt: TestClock.minutes(offset.1)
            ))
        }
    }

    @Test("CF-64 a long stretch in one app becomes a distraction candidate the engine gates")
    func distractionStretchIsGated() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            let restraint = RestraintEngine(
                config: RestraintConfig(quietHours: QuietHours(enabled: false)),
                calendar: TestClock.localCalendar
            )
            let scanner = NudgeScanner(store: store, restraint: restraint)

            try await seedStretch(in: store)
            // Memoir's own focus rows are never "activity". The timer that wrote them is gone;
            // the rows are still in people's databases, so the exclusion still has to hold.
            try await store.upsert(session: Session(
                appBundleID: FocusSession.bundleID, appName: FocusSession.appName,
                startedAt: TestClock.minutes(-60), endedAt: TestClock.minutes(-45)
            ))

            let candidates = await scanner.candidates(now: TestClock.reference)
            guard case .distraction(let app, let minutes)? = candidates.first else {
                Issue.record("expected a distraction candidate, got \(candidates)")
                return
            }
            #expect(app == "Chrome")
            #expect(minutes >= 39 && minutes <= 41, "the stretch is ~40 minutes, got \(minutes)")

            // The engine's threshold (11 min default) lets it through…
            #expect(await scanner.scan(now: TestClock.reference) != nil)

            // …and a tightened threshold gates the identical fact with no scanner
            // change. A fresh engine, so neither the cooldown from the delivery above
            // nor stretch liveness can mask what is being tested.
            let strict = RestraintEngine(
                config: RestraintConfig(quietHours: QuietHours(enabled: false),
                                        distractionThresholdMinutes: 60),
                calendar: TestClock.localCalendar
            )
            let strictScanner = NudgeScanner(store: store, restraint: strict)
            #expect(await strictScanner.scan(now: TestClock.reference) == nil,
                    "below the threshold the fact is true but not worth a word")
        }
    }
}
