//
//  LifecycleTests.swift
//  CF-20, CF-21, CF-22, CF-23. Tier 2: lifecycle and restraint.
//
//  What this file is about: what Memoir does over *time*. Raw captures roll off while the
//  memory they produced stays (CF-20), that memory stays readable once its source is gone
//  (CF-21), the companion holds its tongue (CF-22), and pause actually means paused (CF-23).
//
//  House rules, all enforced here:
//  - every test runs inside `TestWorkspace.with`, so the real
//    `~/Library/Application Support/Memoir` is never touched, not even by `Log.shared`;
//  - no wall clock. `RestraintEngine` gets `TestClock.utcCalendar` and every instant is
//    built with `TestClock.utc(...)`, so these assertions hold in every timezone;
//  - the one place real time is unavoidable is CF-23, because "several intervals passed
//    and nothing was written" is a claim about elapsed time. It is not slept on: a second,
//    still-running loop acts as the clock and the test waits on *its* ticks.
//

import Foundation
import Testing

import MemoirFixtures
@testable import MemoirKit

// MARK: - Shared helpers (prefixed: every test file shares one module)

/// Every capture in the store, oldest id first. `limit: 0` means no limit.
private func lifecycleAllCaptures(_ store: Store) async throws -> [CaptureEvent] {
    try await store.captures(since: .distantPast, limit: 0).sorted { $0.id < $1.id }
}

/// Every entity, soft-deleted ones included, in a stable order.
private func lifecycleAllEntities(_ store: Store) async throws -> [Entity] {
    try await store.entities(kind: nil, includeDeleted: true).sorted { $0.id < $1.id }
}

/// Every provenance row belonging to the given entities, in a stable order.
private func lifecycleAllProvenance(_ store: Store, of entities: [Entity]) async throws -> [Provenance] {
    var rows: [Provenance] = []
    for entity in entities {
        rows.append(contentsOf: try await store.provenance(entityID: entity.id))
    }
    return rows.sorted { $0.id < $1.id }
}

// MARK: - CF-20

@Suite("CF-20 retention rolls off captures but never entities")
struct RetentionLifecycleTests {

    /// The instant every date in this suite is measured from: Monday 16 March 2026, 10:00 UTC.
    private static let now = TestClock.reference

    /// Where a 60 day window cuts. `purgeCaptures` deletes strictly *before* this instant.
    private static let cutoff = TestClock.days(-60)

    @Test("CF-20 a 60 day window deletes old captures, keeps recent ones, and touches no entity")
    func retentionKeepsEntities() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            let now = Self.now

            // Five realistic screens 100 days ago (old enough to roll off, rich enough to
            // produce real entities), plus 120 filler captures spread over the whole 120 days.
            let old = Fixtures.all(startingAt: TestClock.days(-100, from: now))
            let filler = makeCaptures(count: 120, spanningDays: 120, from: TestClock.days(-120, from: now))
            try await seed(store: store, captures: old + filler)

            let memory = MemoryService(store: store, extractors: [RuleExtractor()])
            let touched = try await memory.consolidate(since: .distantPast, now: now)
            #expect(touched > 0, "the fixtures must produce memory, or this flow proves nothing")

            let entitiesBefore = try await lifecycleAllEntities(store)
            let provenanceBefore = try await lifecycleAllProvenance(store, of: entitiesBefore)
            let capturesBefore = try await lifecycleAllCaptures(store)
            let statsBefore = try await store.stats()
            #expect(!entitiesBefore.isEmpty)
            #expect(!provenanceBefore.isEmpty)

            let doomed = capturesBefore.filter { $0.ts < Self.cutoff }
            let survivors = capturesBefore.filter { $0.ts >= Self.cutoff }
            #expect(!doomed.isEmpty, "the seed must straddle the cutoff")
            #expect(!survivors.isEmpty, "the seed must straddle the cutoff")

            let removed = try await memory.applyRetention(captureDays: 60, now: now)
            #expect(removed == doomed.count)

            // Old captures: gone. Not truncated, not emptied. Absent.
            for capture in doomed {
                let found = try await store.capture(id: capture.id)
                #expect(found == nil, "capture at \(TestClock.iso(capture.ts)) should have rolled off")
            }
            // Recent captures: byte-identical to what went in.
            for capture in survivors {
                let found = try await store.capture(id: capture.id)
                #expect(found == capture, "capture at \(TestClock.iso(capture.ts)) should have been kept")
            }

            // The whole point of the flow: memory outlives its raw source.
            let entitiesAfter = try await lifecycleAllEntities(store)
            let provenanceAfter = try await lifecycleAllProvenance(store, of: entitiesAfter)
            #expect(entitiesAfter == entitiesBefore, "retention must not touch a single entity")
            #expect(provenanceAfter == provenanceBefore, "retention must not touch a single provenance row")

            let statsAfter = try await store.stats()
            #expect(statsAfter.entityCount == statsBefore.entityCount)
            #expect(statsAfter.captureCount == survivors.count)
            #expect(statsAfter.captureCount == statsBefore.captureCount - removed)
            let oldest = try #require(statsAfter.oldestCapture)
            #expect(oldest >= Self.cutoff)
        }
    }

    @Test("CF-20 the cutoff is exclusive: a capture exactly on the boundary survives")
    func cutoffBoundaryIsExclusive() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            let now = Self.now

            let justBefore = Fixtures.capture(
                text: "one second too old to keep",
                app: "Notes", bundleID: "com.apple.Notes", windowTitle: nil,
                at: TestClock.seconds(-1, from: Self.cutoff), name: "boundary-before"
            )
            let exactly = Fixtures.capture(
                text: "exactly on the sixty day boundary",
                app: "Notes", bundleID: "com.apple.Notes", windowTitle: nil,
                at: Self.cutoff, name: "boundary-exact"
            )
            let justAfter = Fixtures.capture(
                text: "one second inside the window",
                app: "Notes", bundleID: "com.apple.Notes", windowTitle: nil,
                at: TestClock.seconds(1, from: Self.cutoff), name: "boundary-after"
            )
            try await seed(store: store, captures: [justBefore, exactly, justAfter])

            let memory = MemoryService(store: store, extractors: [RuleExtractor()])
            let removed = try await memory.applyRetention(captureDays: 60, now: now)

            #expect(removed == 1)
            let before = try await store.capture(id: justBefore.id)
            let onCutoff = try await store.capture(id: exactly.id)
            let after = try await store.capture(id: justAfter.id)
            #expect(before == nil)
            #expect(onCutoff != nil, "the boundary instant is kept: the window is [cutoff, now]")
            #expect(after != nil)
        }
    }

    @Test("CF-20 a second retention pass over the same window removes nothing")
    func retentionIsIdempotent() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            let now = Self.now
            try await seed(store: store, captures: makeCaptures(count: 40, spanningDays: 120, from: TestClock.days(-120, from: now)))

            let memory = MemoryService(store: store, extractors: [RuleExtractor()])
            let first = try await memory.applyRetention(captureDays: 60, now: now)
            let remaining = try await lifecycleAllCaptures(store)
            #expect(first > 0)

            let second = try await memory.applyRetention(captureDays: 60, now: now)
            let third = try await memory.applyRetention(captureDays: 60, now: now)
            #expect(second == 0)
            #expect(third == 0)
            let after = try await lifecycleAllCaptures(store)
            #expect(after == remaining)
        }
    }

    @Test("CF-20 a non-positive retention window is refused rather than deleting everything")
    func nonPositiveWindowDeletesNothing() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            let seeded = makeCaptures(count: 12, spanningDays: 120, from: TestClock.days(-120))
            try await seed(store: store, captures: seeded)

            let memory = MemoryService(store: store, extractors: [RuleExtractor()])
            let zero = try await memory.applyRetention(captureDays: 0, now: Self.now)
            let negative = try await memory.applyRetention(captureDays: -30, now: Self.now)

            #expect(zero == 0)
            #expect(negative == 0)
            let after = try await lifecycleAllCaptures(store)
            #expect(after.count == seeded.count, "a nonsense window must never be read as 'delete it all'")
        }
    }

    @Test("CF-20 the full-text index forgets what retention deleted")
    func retentionKeepsSearchHonest() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            let now = Self.now

            let expiring = Fixtures.capture(
                text: "quarterly planning with zarnaquilold as the code name",
                app: "Notes", bundleID: "com.apple.Notes", windowTitle: nil,
                at: TestClock.days(-90, from: now), name: "fts-old"
            )
            let surviving = Fixtures.capture(
                text: "quarterly planning with zarnaquilnew as the code name",
                app: "Notes", bundleID: "com.apple.Notes", windowTitle: nil,
                at: TestClock.days(-3, from: now), name: "fts-new"
            )
            try await seed(store: store, captures: [expiring, surviving])

            let before = try await store.searchCaptures("zarnaquilold", limit: 10)
            #expect(before.count == 1, "the index must find it before retention runs")

            let memory = MemoryService(store: store, extractors: [RuleExtractor()])
            _ = try await memory.applyRetention(captureDays: 60, now: now)

            let purgedHits = try await store.searchCaptures("zarnaquilold", limit: 10)
            let keptHits = try await store.searchCaptures("zarnaquilnew", limit: 10)
            #expect(purgedHits.isEmpty, "a deleted capture must leave the full-text index too")
            #expect(keptHits.map(\.id) == [surviving.id])
        }
    }
}

// MARK: - CF-21

@Suite("CF-21 provenance survives its capture")
struct ProvenanceSurvivalTests {

    private static let now = TestClock.reference

    @Test("CF-21 an entity and its evidence outlive the capture they came from")
    func evidenceOutlivesItsCapture() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            let now = Self.now

            // Everything is old enough to roll off, so every source expires.
            try await seed(store: store, captures: Fixtures.all(startingAt: TestClock.days(-100, from: now)))
            let memory = MemoryService(store: store, extractors: [RuleExtractor()])
            _ = try await memory.consolidate(since: .distantPast, now: now)

            let entities = try await lifecycleAllEntities(store)
            let provenanceBefore = try await lifecycleAllProvenance(store, of: entities)
            #expect(!entities.isEmpty)
            #expect(!provenanceBefore.isEmpty)

            let removed = try await memory.applyRetention(captureDays: 60, now: now)
            #expect(removed > 0)

            // The entities are still there, unchanged.
            let after = try await lifecycleAllEntities(store)
            #expect(after == entities)

            // Reading their evidence does not throw, does not drop rows, and does not hand
            // back a capture id dressed up as if it still resolved.
            var records = 0
            for entity in after {
                let evidence = try await store.evidence(entityID: entity.id)
                let rows = try await store.provenance(entityID: entity.id)
                #expect(evidence.count == rows.count, "no evidence row may be silently dropped")
                for record in evidence {
                    records += 1
                    #expect(record.isSourceExpired, "every source in this fixture has rolled off")
                    #expect(record.capture == nil)
                    #expect(record.sourceDescription == ProvenanceRecord.expiredSourceLabel)
                    #expect(!record.snippet.isEmpty, "the snippet is what keeps it explainable")
                    #expect(!record.captureID.isEmpty, "the id is kept as a record, not resolved")
                    let dangling = try await store.capture(id: record.captureID)
                    #expect(dangling == nil, "and it genuinely no longer resolves")
                }
            }
            #expect(records == provenanceBefore.count)
        }
    }

    @Test("CF-21 one entity can hold a live source and an expired one at the same time")
    func mixedLiveAndExpiredSources() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            let now = Self.now

            let old = Fixtures.slackThread(at: TestClock.days(-100, from: now))
            let recent = Fixtures.standupNotes(at: TestClock.days(-2, from: now))
            let entity = makeEntity(
                kind: .commitment,
                title: "Merge and deploy the rate limiter fix",
                dueAt: TestClock.days(4, from: now),
                at: TestClock.days(-100, from: now)
            )
            let fromOld = makeProvenance(
                entityID: entity.id, captureID: old.id, field: "title",
                snippet: "I'll have the fix merged and deployed by Friday",
                at: TestClock.days(-100, from: now)
            )
            let fromRecent = makeProvenance(
                entityID: entity.id, captureID: recent.id, field: "detail",
                snippet: "Rate limiter shipped behind a flag",
                at: TestClock.days(-2, from: now)
            )
            try await seed(
                store: store,
                captures: [old, recent],
                entities: [entity],
                provenance: [fromOld, fromRecent]
            )

            let memory = MemoryService(store: store, extractors: [RuleExtractor()])
            _ = try await memory.applyRetention(captureDays: 60, now: now)

            let evidence = try await store.evidence(entityID: entity.id)
            #expect(evidence.count == 2)

            let expired = try #require(evidence.first { $0.captureID == old.id })
            #expect(expired.isSourceExpired)
            #expect(expired.capture == nil)
            #expect(expired.sourceDescription == "Source expired")
            #expect(expired.snippet == fromOld.snippet, "the quote survives the screen")
            #expect(expired.field == "title")

            let live = try #require(evidence.first { $0.captureID == recent.id })
            #expect(!live.isSourceExpired)
            #expect(live.capture?.id == recent.id)
            #expect(live.sourceDescription.contains("Notes"))
            #expect(live.sourceDescription.contains("Standup 16 March"))
        }
    }

    @Test("CF-21 evidence for an unknown entity is empty rather than an error")
    func unknownEntityDegradesQuietly() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            let evidence = try await store.evidence(entityID: TestID.stable("no-such-entity"))
            #expect(evidence.isEmpty)
        }
    }

    @Test("CF-21 a live source resolves to its app and window, an expired one never invents them")
    func sourceDescriptionIsHonest() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()

            let titled = Fixtures.slackThread(at: TestClock.days(-1))
            let untitled = Fixtures.capture(
                text: "no window title on this one",
                app: "Terminal", bundleID: "com.apple.Terminal", windowTitle: nil,
                at: TestClock.days(-1), name: "untitled"
            )
            let entity = makeEntity(kind: .note, title: "Source description probe")
            let a = makeProvenance(entityID: entity.id, captureID: titled.id, snippet: "Heads up", at: TestClock.days(-1))
            let b = makeProvenance(entityID: entity.id, captureID: untitled.id, snippet: "no window title", at: TestClock.days(-1))
            let ghost = makeProvenance(
                entityID: entity.id,
                captureID: TestID.stable("capture-that-never-existed"),
                snippet: "written before the capture was ever stored",
                at: TestClock.days(-1)
            )
            try await seed(
                store: store,
                captures: [titled, untitled],
                entities: [entity],
                provenance: [a, b, ghost]
            )

            let evidence = try await store.evidence(entityID: entity.id)
            #expect(evidence.count == 3)

            let withTitle = try #require(evidence.first { $0.captureID == titled.id })
            #expect(withTitle.sourceDescription == "Slack · #eng-platform - Acme")

            let withoutTitle = try #require(evidence.first { $0.captureID == untitled.id })
            #expect(withoutTitle.sourceDescription == "Terminal")

            // A capture id that never existed is indistinguishable from one that rolled off,
            // and must be presented the same honest way rather than crashing a reader.
            let missing = try #require(evidence.first { $0.captureID == ghost.captureID })
            #expect(missing.isSourceExpired)
            #expect(missing.sourceDescription == ProvenanceRecord.expiredSourceLabel)
            #expect(missing.snippet == ghost.snippet)
        }
    }

    @Test("CF-21 the context packet cites only captures that still exist")
    func contextNeverCitesAPurgedCapture() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            let now = Self.now

            try await seed(store: store, captures: Fixtures.all(startingAt: TestClock.days(-100, from: now))
                + Fixtures.all(startingAt: TestClock.hours(-2, from: now)))
            let memory = MemoryService(store: store, extractors: [RuleExtractor()])
            _ = try await memory.consolidate(since: .distantPast, now: now)
            _ = try await memory.applyRetention(captureDays: 60, now: now)

            let packet = try await memory.context(for: "what do I owe anyone", budget: 2_000, now: now)
            #expect(!packet.summary.isEmpty)
            #expect(!packet.captureIDs.isEmpty, "the recent half of the seed is still there")
            for id in packet.captureIDs {
                let capture = try await store.capture(id: id)
                #expect(capture != nil, "a cited capture must resolve: \(id)")
            }
            for id in packet.entityIDs {
                let entity = try await store.entity(id: id)
                #expect(entity != nil)
            }
            assertNoNetwork()
        }
    }
}

// MARK: - CF-22

@Suite("CF-22 the restraint gate holds")
struct RestraintGateTests {

    /// Every instant in this suite is built in UTC and the engine is given a UTC calendar,
    /// so "23:30" means 23:30 to the code under test no matter where the suite runs.
    private static func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        TestClock.utc(2026, 3, day, hour, minute)
    }

    private static func engine(
        quiet: QuietHours = .off,
        cooldown: Double = 0,
        cap: Int = 100,
        suppressDuringFocus: Bool = true,
        distractionThreshold: Int = 11
    ) -> RestraintEngine {
        RestraintEngine(
            config: RestraintConfig(
                quietHours: quiet,
                cooldownSeconds: cooldown,
                maxNudgesPerDay: cap,
                suppressDuringFocus: suppressDuringFocus,
                distractionThresholdMinutes: distractionThreshold
            ),
            calendar: TestClock.utcCalendar
        )
    }

    // MARK: Quiet hours

    @Test("CF-22 quiet hours wrapping midnight silence 23:30 and 06:30 but not midday")
    func quietHoursWrapMidnight() async throws {
        try await TestWorkspace.with { _ in
            let engine = Self.engine(quiet: QuietHours(start: 22, end: 7))

            let lateEvening = Self.at(16, 23, 30)
            let earlyMorning = Self.at(17, 6, 30)
            let midday = Self.at(17, 12, 0)

            #expect(await engine.propose(.idleReturn, now: lateEvening) == nil)
            #expect(await engine.evaluate(.idleReturn, now: lateEvening).reason == .quietHours)

            #expect(await engine.propose(.idleReturn, now: earlyMorning) == nil)
            #expect(await engine.evaluate(.idleReturn, now: earlyMorning).reason == .quietHours)

            #expect(await engine.propose(.idleReturn, now: midday) == .idleReturn)
        }
    }

    @Test("CF-22 the quiet window is half open: 22:00 is silent, 07:00 is not")
    func quietHourBoundaries() async throws {
        try await TestWorkspace.with { _ in
            let engine = Self.engine(quiet: QuietHours(start: 22, end: 7))

            // evaluate() books nothing, so one engine can answer every boundary question.
            #expect(await engine.evaluate(.idleReturn, now: Self.at(16, 21, 59)).isAllowed)
            #expect(await engine.evaluate(.idleReturn, now: Self.at(16, 22, 0)).reason == .quietHours)
            #expect(await engine.evaluate(.idleReturn, now: Self.at(17, 0, 0)).reason == .quietHours)
            #expect(await engine.evaluate(.idleReturn, now: Self.at(17, 6, 59)).reason == .quietHours)
            #expect(await engine.evaluate(.idleReturn, now: Self.at(17, 7, 0)).isAllowed)
        }
    }

    @Test("CF-22 a same-day quiet window silences only its own hours")
    func quietHoursWithoutWrap() async throws {
        try await TestWorkspace.with { _ in
            let engine = Self.engine(quiet: QuietHours(start: 13, end: 15))

            #expect(await engine.evaluate(.idleReturn, now: Self.at(16, 12, 59)).isAllowed)
            #expect(await engine.evaluate(.idleReturn, now: Self.at(16, 13, 0)).reason == .quietHours)
            #expect(await engine.evaluate(.idleReturn, now: Self.at(16, 14, 59)).reason == .quietHours)
            #expect(await engine.evaluate(.idleReturn, now: Self.at(16, 15, 0)).isAllowed)
            #expect(await engine.evaluate(.idleReturn, now: Self.at(17, 3, 0)).isAllowed)
        }
    }

    @Test("CF-22 disabled quiet hours let the small hours through, all-day quiet never does")
    func quietHoursDegenerateCases() async throws {
        try await TestWorkspace.with { _ in
            let disabled = Self.engine(quiet: .off)
            #expect(await disabled.propose(.idleReturn, now: Self.at(16, 23, 30)) == .idleReturn)

            let always = Self.engine(quiet: .allDay)
            for hour in [0, 6, 12, 18, 23] {
                #expect(await always.propose(.idleReturn, now: Self.at(16, hour, 0)) == nil)
                #expect(await always.evaluate(.idleReturn, now: Self.at(16, hour, 0)).reason == .quietHours)
            }
        }
    }

    // MARK: Cooldown

    @Test("CF-22 the cooldown holds every nudge, not just a repeat of the same one")
    func cooldownIsGlobal() async throws {
        try await TestWorkspace.with { _ in
            let engine = Self.engine(cooldown: 900)
            let start = Self.at(16, 12, 0)

            #expect(await engine.propose(.idleReturn, now: start) == .idleReturn)

            let oneSecondLater = TestClock.seconds(1, from: start)
            #expect(await engine.propose(.dailySummaryReady, now: oneSecondLater) == nil)
            #expect(await engine.evaluate(.dailySummaryReady, now: oneSecondLater).reason == .cooldown)

            let oneSecondEarly = TestClock.seconds(899, from: start)
            #expect(await engine.propose(.dailySummaryReady, now: oneSecondEarly) == nil)

            let clear = TestClock.seconds(900, from: start)
            #expect(await engine.propose(.dailySummaryReady, now: clear) == .dailySummaryReady)
        }
    }

    @Test("CF-22 a held-back nudge books nothing, so the cooldown starts at the delivery")
    func suppressionBooksNothing() async throws {
        try await TestWorkspace.with { _ in
            let engine = Self.engine(quiet: QuietHours(start: 22, end: 7), cooldown: 900, cap: 3)

            // Twenty attempts inside quiet hours.
            for minute in 0..<20 {
                #expect(await engine.propose(.idleReturn, now: Self.at(16, 23, minute)) == nil)
            }
            #expect(await engine.deliveredCount(now: Self.at(16, 23, 30)) == 0)

            // The cap and the cooldown are untouched: three deliveries still fit the new day.
            #expect(await engine.propose(.idleReturn, now: Self.at(17, 9, 0)) == .idleReturn)
            #expect(await engine.propose(.idleReturn, now: Self.at(17, 9, 15)) == .idleReturn)
            #expect(await engine.propose(.idleReturn, now: Self.at(17, 9, 30)) == .idleReturn)
            #expect(await engine.propose(.idleReturn, now: Self.at(17, 9, 45)) == nil)
            #expect(await engine.evaluate(.idleReturn, now: Self.at(17, 9, 45)).reason == .dailyCap)
        }
    }

    // MARK: Daily cap

    @Test("CF-22 the daily cap stops the run once it is reached")
    func dailyCapHolds() async throws {
        try await TestWorkspace.with { _ in
            let engine = Self.engine(cap: 3)

            #expect(await engine.propose(.idleReturn, now: Self.at(16, 9, 0)) == .idleReturn)
            #expect(await engine.propose(.idleReturn, now: Self.at(16, 9, 5)) == .idleReturn)
            #expect(await engine.propose(.idleReturn, now: Self.at(16, 9, 10)) == .idleReturn)
            #expect(await engine.deliveredCount(now: Self.at(16, 9, 10)) == 3)

            #expect(await engine.propose(.idleReturn, now: Self.at(16, 9, 15)) == nil)
            #expect(await engine.evaluate(.idleReturn, now: Self.at(16, 9, 15)).reason == .dailyCap)
            #expect(await engine.propose(.dailySummaryReady, now: Self.at(16, 20, 0)) == nil)
            #expect(await engine.deliveredCount(now: Self.at(16, 23, 59)) == 3)
        }
    }

    @Test("CF-22 a cap of zero means the companion never speaks")
    func zeroCapNeverSpeaks() async throws {
        try await TestWorkspace.with { _ in
            let engine = Self.engine(cap: 0)
            #expect(await engine.propose(.idleReturn, now: Self.at(16, 9, 0)) == nil)
            #expect(await engine.evaluate(.dailySummaryReady, now: Self.at(16, 15, 0)).reason == .dailyCap)
        }
    }

    @Test("CF-22 the daily counter resets on the local calendar day boundary")
    func countersResetAtMidnight() async throws {
        try await TestWorkspace.with { _ in
            let engine = Self.engine(cap: 2)

            #expect(await engine.propose(.idleReturn, now: Self.at(16, 23, 40)) == .idleReturn)
            #expect(await engine.propose(.idleReturn, now: Self.at(16, 23, 50)) == .idleReturn)
            #expect(await engine.deliveredCount(now: Self.at(16, 23, 50)) == 2)

            // One minute before midnight the day is still spent.
            #expect(await engine.propose(.idleReturn, now: Self.at(16, 23, 59)) == nil)
            #expect(await engine.evaluate(.idleReturn, now: Self.at(16, 23, 59)).reason == .dailyCap)

            // At the stroke of local midnight the allowance is new.
            #expect(await engine.propose(.idleReturn, now: Self.at(17, 0, 0)) == .idleReturn)
            #expect(await engine.deliveredCount(now: Self.at(17, 0, 0)) == 1)
            #expect(await engine.propose(.idleReturn, now: Self.at(17, 0, 10)) == .idleReturn)
            #expect(await engine.propose(.idleReturn, now: Self.at(17, 0, 20)) == nil)
            #expect(await engine.deliveredCount(now: Self.at(17, 0, 20)) == 2)
        }
    }

    @Test("CF-22 the day boundary is the user's local midnight, not UTC")
    func dayBoundaryIsLocal() async throws {
        try await TestWorkspace.with { _ in
            // This engine gets the machine's own calendar, which is what production uses.
            // Everything is derived from it rather than hardcoded, so the assertion holds in
            // any timezone and across a daylight saving change.
            let calendar = TestClock.localCalendar
            let engine = RestraintEngine(
                config: RestraintConfig(
                    quietHours: .off,
                    cooldownSeconds: 0,
                    maxNudgesPerDay: 1,
                    suppressDuringFocus: true,
                    distractionThresholdMinutes: 11
                ),
                calendar: calendar
            )

            let today = calendar.startOfDay(for: TestClock.reference)
            let lateEvening = try #require(calendar.date(bySettingHour: 23, minute: 0, second: 0, of: TestClock.reference))
            let nextMidnight = try #require(calendar.date(byAdding: .day, value: 1, to: today))
            #expect(TestClock.sameLocalDay(today, lateEvening))
            #expect(!TestClock.sameLocalDay(today, nextMidnight))

            #expect(await engine.propose(.idleReturn, now: lateEvening) == .idleReturn)
            #expect(await engine.propose(.idleReturn, now: TestClock.minutes(30, from: lateEvening)) == nil)
            #expect(await engine.evaluate(.idleReturn, now: TestClock.minutes(30, from: lateEvening)).reason == .dailyCap)

            #expect(await engine.propose(.idleReturn, now: nextMidnight) == .idleReturn)
            #expect(await engine.deliveredCount(now: nextMidnight) == 1)
        }
    }

    // MARK: Dismissal backoff

    @Test("CF-22 dismissal backoff escalates one hour, then four, then the rest of the day")
    func dismissalBackoffEscalates() async throws {
        try await TestWorkspace.with { _ in
            let engine = Self.engine()
            let stretch = Nudge.distraction(appName: "Xcode", minutes: 90)

            // First dismissal: one hour of silence.
            let first = Self.at(16, 9, 0)
            await engine.recordDismissal(stretch, now: first)
            #expect(await engine.propose(stretch, now: TestClock.minutes(59, from: first)) == nil)
            #expect(await engine.evaluate(stretch, now: TestClock.minutes(59, from: first)).reason == .dismissedRecently)
            // Backoff is per nudge: nothing else is muted by it.
            #expect(await engine.evaluate(.dailySummaryReady, now: TestClock.minutes(59, from: first)).isAllowed)
            #expect(await engine.propose(stretch, now: TestClock.hours(1, from: first)) == stretch)

            // Second dismissal: four hours.
            let second = TestClock.hours(1, from: first)   // 10:00
            await engine.recordDismissal(stretch, now: second)
            #expect(await engine.propose(stretch, now: TestClock.minutes(239, from: second)) == nil)
            #expect(await engine.propose(stretch, now: TestClock.hours(4, from: second)) == stretch)

            // Third dismissal: silence for the rest of the local day.
            let third = TestClock.hours(4, from: second)   // 14:00
            await engine.recordDismissal(stretch, now: third)
            #expect(await engine.propose(stretch, now: Self.at(16, 18, 0)) == nil)
            #expect(await engine.propose(stretch, now: Self.at(16, 23, 59)) == nil)
            #expect(await engine.evaluate(stretch, now: Self.at(16, 23, 59)).reason == .dismissedRecently)
            #expect(await engine.propose(stretch, now: Self.at(17, 0, 0)) == stretch)
        }
    }

    @Test("CF-22 the escalation starts over on the next local day")
    func dismissalEscalationResetsDaily() async throws {
        try await TestWorkspace.with { _ in
            let engine = Self.engine()
            let nudge = Nudge.distraction(appName: "Safari", minutes: 30)

            for hour in [9, 10, 14] {
                await engine.recordDismissal(nudge, now: Self.at(16, hour, 0))
            }
            #expect(await engine.propose(nudge, now: Self.at(16, 23, 59)) == nil)

            // A fresh dismissal on the new day buys one hour again, not the rest of the day.
            let next = Self.at(17, 9, 0)
            await engine.recordDismissal(nudge, now: next)
            #expect(await engine.propose(nudge, now: Self.at(17, 9, 59)) == nil)
            #expect(await engine.propose(nudge, now: Self.at(17, 10, 0)) == nudge)
        }
    }

    @Test("CF-22 a dismissal is keyed by identity, not by payload")
    func dismissalIsKeyedByIdentity() async throws {
        try await TestWorkspace.with { _ in
            let engine = Self.engine()
            let at9 = Self.at(16, 9, 0)
            await engine.recordDismissal(.distraction(appName: "Safari", minutes: 12), now: at9)

            // The minute count keeps climbing; the dismissal still holds.
            let later = Self.at(16, 9, 30)
            #expect(await engine.propose(.distraction(appName: "Safari", minutes: 40), now: later) == nil)
            // A different app is a different nudge.
            #expect(await engine.propose(.distraction(appName: "Xcode", minutes: 40), now: later)
                    == .distraction(appName: "Xcode", minutes: 40))
        }
    }

    @Test("CF-22 a dismissal re-arms the global cooldown")
    func dismissalRearmsCooldown() async throws {
        try await TestWorkspace.with { _ in
            let engine = Self.engine(cooldown: 900)
            let at9 = Self.at(16, 9, 0)
            await engine.recordDismissal(.idleReturn, now: at9)

            #expect(await engine.propose(.dailySummaryReady, now: TestClock.seconds(899, from: at9)) == nil)
            #expect(await engine.evaluate(.dailySummaryReady, now: TestClock.seconds(899, from: at9)).reason == .cooldown)
            #expect(await engine.propose(.dailySummaryReady, now: TestClock.seconds(900, from: at9)) == .dailySummaryReady)
        }
    }

    // MARK: Focus

    @Test("CF-22 Focus mode suppresses everything until it is turned off")
    func focusSuppresses() async throws {
        try await TestWorkspace.with { _ in
            let engine = Self.engine()
            let noon = Self.at(16, 12, 0)

            await engine.setFocusMode(true)
            #expect(await engine.isFocusMode())
            for nudge in [Nudge.idleReturn, .dailySummaryReady, .distraction(appName: "Slack", minutes: 30)] {
                #expect(await engine.propose(nudge, now: noon) == nil)
                #expect(await engine.evaluate(nudge, now: noon).reason == .focusMode)
            }

            await engine.setFocusMode(false)
            #expect(await engine.propose(.idleReturn, now: noon) == .idleReturn)
        }
    }

    @Test("CF-22 Focus is ignored when the user asked for it to be")
    func focusCanBeOverridden() async throws {
        try await TestWorkspace.with { _ in
            let engine = Self.engine(suppressDuringFocus: false)
            await engine.setFocusMode(true)
            #expect(await engine.propose(.idleReturn, now: Self.at(16, 12, 0)) == .idleReturn)
        }
    }

    // MARK: Distraction threshold, and rule ordering

    @Test("CF-22 a distraction shorter than the threshold is never mentioned")
    func distractionThreshold() async throws {
        try await TestWorkspace.with { _ in
            let engine = Self.engine(distractionThreshold: 11)
            let noon = Self.at(16, 12, 0)

            #expect(await engine.propose(.distraction(appName: "Safari", minutes: 10), now: noon) == nil)
            #expect(await engine.evaluate(.distraction(appName: "Safari", minutes: 10), now: noon).reason
                    == .belowDistractionThreshold)
            // "at least this many minutes": exactly the threshold qualifies.
            #expect(await engine.propose(.distraction(appName: "Safari", minutes: 11), now: noon)
                    == .distraction(appName: "Safari", minutes: 11))
        }
    }

    @Test("CF-22 every rule reports its own reason, in the documented order")
    func ruleOrderIsStable() async throws {
        try await TestWorkspace.with { _ in
            let engine = Self.engine(quiet: QuietHours(start: 22, end: 7), cooldown: 900, cap: 1)
            let quiet = Self.at(16, 23, 0)

            // Eligibility is checked before quiet hours.
            #expect(await engine.evaluate(.distraction(appName: "Safari", minutes: 2), now: quiet).reason
                    == .belowDistractionThreshold)
            // Quiet hours before Focus.
            await engine.setFocusMode(true)
            #expect(await engine.evaluate(.idleReturn, now: quiet).reason == .quietHours)
            // Focus before backoff.
            let noon = Self.at(17, 12, 0)
            await engine.recordDismissal(.idleReturn, now: Self.at(17, 11, 50))
            #expect(await engine.evaluate(.idleReturn, now: noon).reason == .focusMode)
            // Backoff before the cap.
            await engine.setFocusMode(false)
            #expect(await engine.evaluate(.idleReturn, now: noon).reason == .dismissedRecently)
            // The cap before the cooldown.
            #expect(await engine.propose(.dailySummaryReady, now: Self.at(17, 13, 0)) == .dailySummaryReady)
            #expect(await engine.evaluate(.dailySummaryReady, now: Self.at(17, 13, 1)).reason == .dailyCap)
        }
    }

    @Test("CF-22 the silent configuration never lets anything through")
    func silentConfigIsSilent() async throws {
        try await TestWorkspace.with { _ in
            let engine = RestraintEngine(config: .silent, calendar: TestClock.utcCalendar)
            let nudges: [Nudge] = [
                .idleReturn,
                .dailySummaryReady,
                .distraction(appName: "Safari", minutes: 90),
            ]
            for day in [16, 17] {
                for hour in stride(from: 0, to: 24, by: 3) {
                    for nudge in nudges {
                        #expect(await engine.propose(nudge, now: Self.at(day, hour, 0)) == nil)
                    }
                }
            }
        }
    }

    @Test("CF-22 reset clears the counters and the backoff without unmuting quiet hours")
    func resetClearsState() async throws {
        try await TestWorkspace.with { _ in
            let engine = Self.engine(quiet: QuietHours(start: 22, end: 7), cap: 1)

            #expect(await engine.propose(.idleReturn, now: Self.at(16, 9, 0)) == .idleReturn)
            await engine.recordDismissal(.dailySummaryReady, now: Self.at(16, 9, 30))
            #expect(await engine.propose(.dailySummaryReady, now: Self.at(16, 10, 0)) == nil)

            await engine.reset()
            #expect(await engine.deliveredCount(now: Self.at(16, 10, 0)) == 0)
            #expect(await engine.propose(.dailySummaryReady, now: Self.at(16, 10, 0)) == .dailySummaryReady)
            // Quiet hours are configuration, not state: reset must not open that door.
            #expect(await engine.propose(.idleReturn, now: Self.at(16, 23, 0)) == nil)
        }
    }
}

// MARK: - CF-23

/// A `CaptureSource` that stands in for the accessibility walk: it counts how often it was
/// asked, can be parked mid-read, and hands back a distinct capture every time so nothing
/// dedupes.
///
/// Faking here is legitimate (the accessibility API is a process boundary), and it is also
/// the only way to know *exactly* how many reads a loop performed.
final class LifecycleCaptureSource: CaptureSource, @unchecked Sendable {

    /// Which counter a waiter is watching.
    enum Signal: Sendable {
        /// `snapshot()` was entered, before any parking.
        case entered
        /// `snapshot()` returned an event.
        case returned
    }

    /// The app this source pretends to be reading.
    let appName: String
    let bundleID: String

    private let lock = NSLock()
    private var enteredCount = 0
    private var returnedCount = 0
    private var parkFrom: Int?
    private var gateOpen = true
    private var gateWaiters: [CheckedContinuation<Void, Never>] = []
    private var waiters: [(signal: Signal, threshold: Int, continuation: CheckedContinuation<Bool, Never>)] = []

    init(appName: String, bundleID: String) {
        self.appName = appName
        self.bundleID = bundleID
    }

    /// A fake frontmost app matching this source, for `CaptureLoop`'s session bookkeeping.
    var frontmost: FrontmostApp {
        FrontmostApp(bundleID: bundleID, name: appName, pid: 1)
    }

    /// How many reads have been started.
    var entered: Int { lock.withLock { enteredCount } }

    /// How many reads have produced an event.
    var returned: Int { lock.withLock { returnedCount } }

    /// Parks the `index`-th read (1-based) and every read after it until ``openGate()``.
    ///
    /// This is how the "stopped while reading the screen" race is made deterministic instead
    /// of hoped for.
    func park(fromRead index: Int) {
        lock.withLock {
            parkFrom = index
            gateOpen = false
        }
    }

    /// Releases a parked read.
    func openGate() {
        let waiting: [CheckedContinuation<Void, Never>] = lock.withLock {
            gateOpen = true
            let pending = gateWaiters
            gateWaiters = []
            return pending
        }
        for continuation in waiting { continuation.resume() }
    }

    // MARK: CaptureSource

    func snapshot() async throws -> CaptureEvent? {
        let index: Int = lock.withLock {
            enteredCount += 1
            return enteredCount
        }
        resume(.entered, count: index)

        if lock.withLock({ parkFrom.map { index >= $0 } ?? false }) {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                lock.lock()
                if gateOpen {
                    lock.unlock()
                    continuation.resume()
                } else {
                    gateWaiters.append(continuation)
                    lock.unlock()
                }
            }
        }

        let text = "\(appName) screen reading \(index): the quarterly numbers are on the board"
        let event = CaptureEvent(
            id: TestID.stable("lifecycle-capture", bundleID, String(index)),
            ts: TestClock.seconds(Double(index), from: TestClock.reference),
            appBundleID: bundleID,
            appName: appName,
            windowTitle: "reading \(index)",
            text: text,
            textHash: AccessibilityCapture.textHash(text)
        )

        let done: Int = lock.withLock {
            returnedCount += 1
            return returnedCount
        }
        resume(.returned, count: done)
        return event
    }

    // MARK: Waiting

    /// Suspends until the given counter reaches `threshold`.
    ///
    /// - Returns: true when the counter got there, false when ``releaseWaiters()`` gave up.
    func wait(_ signal: Signal, reaches threshold: Int) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            lock.lock()
            let current = signal == .entered ? enteredCount : returnedCount
            if current >= threshold {
                lock.unlock()
                continuation.resume(returning: true)
            } else {
                waiters.append((signal, threshold, continuation))
                lock.unlock()
            }
        }
    }

    /// Fails every pending wait. Called by the timeout so nothing can hang the suite.
    func releaseWaiters() {
        let pending: [CheckedContinuation<Bool, Never>] = lock.withLock {
            let all = waiters.map(\.continuation)
            waiters = []
            return all
        }
        for continuation in pending { continuation.resume(returning: false) }
    }

    private func resume(_ signal: Signal, count: Int) {
        let ready: [CheckedContinuation<Bool, Never>] = lock.withLock {
            let hit = waiters.filter { $0.signal == signal && count >= $0.threshold }
            waiters.removeAll { $0.signal == signal && count >= $0.threshold }
            return hit.map(\.continuation)
        }
        for continuation in ready { continuation.resume(returning: true) }
    }
}

/// Waits for a source's counter to reach `threshold`, failing the test rather than hanging.
///
/// The timeout is a safety net, never the synchronisation: the happy path resumes the moment
/// the counter is hit.
@discardableResult
private func lifecycleAwait(
    _ source: LifecycleCaptureSource,
    _ signal: LifecycleCaptureSource.Signal,
    reaches threshold: Int,
    timeout: Double = 30,
    _ what: String,
    sourceLocation: SourceLocation = #_sourceLocation
) async -> Bool {
    let reached = await withTaskGroup(of: Bool.self) { group in
        group.addTask { await source.wait(signal, reaches: threshold) }
        group.addTask {
            try? await Task.sleep(for: .seconds(timeout))
            source.releaseWaiters()
            return false
        }
        let first = await group.next() ?? false
        group.cancelAll()
        source.releaseWaiters()
        await group.waitForAll()
        return first
    }
    #expect(reached, "timed out waiting for \(what)", sourceLocation: sourceLocation)
    return reached
}

@Suite("CF-23 pause means paused")
struct PauseLifecycleTests {

    private static func config() -> CaptureConfig {
        var config = CaptureConfig(
            idleThresholdSeconds: 5,
            excludedBundleIDs: [],
            captureWindowTitles: false,
            maxTextLength: 20_000
        )
        // Capture is event-driven: a frozen fake screen with a frozen fake app produces no
        // app switch, no window change and no typing, so nothing would ever trigger. This
        // test is about PAUSE semantics, not about trigger detection (that is covered by
        // the TriggerDetector suite), so drive it with a fast idle-fallback and no floors.
        config.pollIntervalSeconds = 0.05
        config.minCaptureIntervalSeconds = 0
        config.checkpointIntervalSeconds = 0
        config.idleCaptureIntervalSeconds = 0.05
        return config
    }

    private static func loop(source: LifecycleCaptureSource, store: Store) -> CaptureLoop {
        CaptureLoop(
            source: source,
            store: store,
            config: config(),
            frontmostApp: { source.frontmost },
            // The machine running the suite may have been untouched for hours. Idleness is a
            // process-external reading and is injected, or capture would silently switch off.
            idleSeconds: { 0 }
        )
    }

    private static func rows(_ store: Store, from source: LifecycleCaptureSource) async throws -> [CaptureEvent] {
        try await store.captures(since: .distantPast, limit: 0)
            .filter { $0.appBundleID == source.bundleID }
            .sorted { $0.id < $1.id }
    }

    @Test("CF-23 a paused loop writes nothing for several intervals, then resumes")
    func pauseThenResume() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()

            let subject = LifecycleCaptureSource(appName: "Subject", bundleID: "sh.memoir.tests.subject")
            // A second loop that is never paused. It is the clock: waiting for its ticks is
            // how this test knows several intervals really elapsed, without sleeping on it.
            let clock = LifecycleCaptureSource(appName: "Clock", bundleID: "sh.memoir.tests.clock")

            let subjectLoop = Self.loop(source: subject, store: store)
            let clockLoop = Self.loop(source: clock, store: store)

            await subjectLoop.start()
            await clockLoop.start()
            #expect(await subjectLoop.isRunning)

            // Capture is running: the very first tick writes.
            await lifecycleAwait(subject, .returned, reaches: 1, "the first capture")
            await lifecycleAwait(clock, .returned, reaches: 1, "the clock loop's first capture")

            // Park the next read so the loop is provably *inside* a screen reading when it is
            // paused. This is the case a naive stop() gets wrong.
            subject.park(fromRead: 2)
            await lifecycleAwait(subject, .entered, reaches: 2, "the loop to enter a second read")

            await subjectLoop.stop(now: TestClock.reference)
            #expect(await subjectLoop.isRunning == false)

            let atPause = try await Self.rows(store, from: subject)
            let writesAtPause = await subjectLoop.capturesWritten
            #expect(!atPause.isEmpty, "capture must have been working before it was paused")

            // Let the parked read finish. Its result was read from the screen before the pause
            // and must never reach the database.
            subject.openGate()
            await lifecycleAwait(subject, .returned, reaches: 2, "the parked read to finish")

            // Several intervals of real time, proven by the clock loop rather than assumed.
            let ticksBefore = clock.returned
            await lifecycleAwait(clock, .returned, reaches: ticksBefore + 3, "three more clock ticks")

            let whilePaused = try await Self.rows(store, from: subject)
            #expect(whilePaused == atPause, "a paused loop wrote \(whilePaused.count - atPause.count) new rows")
            #expect(await subjectLoop.capturesWritten == writesAtPause)

            // Polling stops, asserted as "the count settles and never moves again" rather
            // than as an exact number.
            //
            // `stop()` can land while a read has already been entered, so the count at this
            // point is legitimately 2 or 3 depending on which side of the pause that read
            // fell. It was pinned at 2 and went red roughly one run in four. The exact figure
            // was never the claim: an extra in-flight read writes nothing (the two
            // assertions above are what prove that), and what actually has to hold is that
            // the loop stops going back to the screen.
            let settled = subject.entered
            let ticksNow = clock.returned
            await lifecycleAwait(clock, .returned, reaches: ticksNow + 3, "three further clock ticks")
            #expect(subject.entered == settled,
                    "a paused loop kept polling: \(subject.entered - settled) more reads over three ticks")

            // Resume: capture continues.
            await subjectLoop.start()
            #expect(await subjectLoop.isRunning)
            await lifecycleAwait(subject, .returned, reaches: 3, "capture to resume")
            await lifecycleAwait(subject, .returned, reaches: 4, "capture to keep going")

            var resumed = try await Self.rows(store, from: subject)
            if resumed.count <= atPause.count {
                // The row lands just after the read returns; wait one more read rather than
                // racing it.
                await lifecycleAwait(subject, .returned, reaches: 5, "the resumed rows to land")
                resumed = try await Self.rows(store, from: subject)
            }
            #expect(resumed.count > atPause.count, "resume must actually capture again")
            #expect(Set(atPause.map(\.id)).isSubset(of: Set(resumed.map(\.id))), "resuming must not lose what was captured before")

            await subjectLoop.stop(now: TestClock.reference)
            await clockLoop.stop(now: TestClock.reference)

            // The clock loop was never paused and kept writing throughout.
            let clockRows = try await Self.rows(store, from: clock)
            #expect(clockRows.count >= 4, "the clock loop proves the environment kept capturing")
            assertNoNetwork()
        }
    }

    @Test("CF-23 a loop that was never started never writes")
    func neverStartedNeverWrites() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            let source = LifecycleCaptureSource(appName: "Idle", bundleID: "sh.memoir.tests.neverstarted")
            let loop = Self.loop(source: source, store: store)

            #expect(await loop.isRunning == false)
            // Stopping something that never ran is a no-op, not a crash.
            await loop.stop(now: TestClock.reference)
            #expect(await loop.isRunning == false)

            #expect(source.entered == 0)
            let rows = try await Self.rows(store, from: source)
            #expect(rows.isEmpty)
            let stats = try await store.stats()
            #expect(stats.captureCount == 0)
        }
    }

    @Test("CF-23 stopping twice is harmless and leaves the loop stopped")
    func stopIsIdempotent() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            let source = LifecycleCaptureSource(appName: "Twice", bundleID: "sh.memoir.tests.twice")
            let loop = Self.loop(source: source, store: store)

            await loop.start()
            await lifecycleAwait(source, .returned, reaches: 1, "the first capture")
            await loop.stop(now: TestClock.reference)
            await loop.stop(now: TestClock.reference)
            #expect(await loop.isRunning == false)

            let after = source.entered
            let rows = try await Self.rows(store, from: source)
            #expect(rows.count <= after)
            #expect(rows.count >= 1)
        }
    }
}
