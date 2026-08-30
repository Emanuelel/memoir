//
//  MemoryPipelineTests.swift
//  CF-14 · CF-15 · CF-16 · CF-19
//
//  The memory pipeline end of the contract in FLOWS.md:
//
//  - CF-14  extraction finds commitments, and relative dates resolve against the
//           capture's own timestamp (never the wall clock), and shell noise
//           produces nothing at all.
//  - CF-15  every entity is traceable: at least one provenance row, pointing at a
//           real capture, carrying a snippet that literally occurs in that capture.
//  - CF-16  consolidation is idempotent: three passes, one set of entities.
//  - CF-19  a context packet over 500 entities and 5 000 captures respects its
//           token budget as a hard ceiling, keeps the pinned and the urgent, and
//           returns fast.
//
//  Everything runs against a real `Store` on a real SQLite file in a throwaway
//  directory, through the real `RuleExtractor` and the real `MemoryService`. The
//  only fake is `StubBrain`, which stands in for the process-crossing model call.
//

import Foundation
import Testing

import MemoirFixtures
@testable import MemoirKit

@Suite("Memory pipeline")
struct MemoryPipelineTests {

    // MARK: - CF-14 · Extraction finds commitments with dates

    /// The reference instant is Monday 16 March 2026. Every absolute date asserted in the
    /// CF-14 tests is stated in full, which is only meaningful if that is genuinely the local
    /// day, so it is checked first. A machine in an exotic timezone then fails on the
    /// assumption with a clear message instead of failing on the flow.
    private func requireReferenceIsMonday16March(_ sourceLocation: SourceLocation = #_sourceLocation) {
        let c = TestClock.localCalendar.dateComponents(
            [.year, .month, .day, .weekday], from: TestClock.reference
        )
        #expect(
            c.year == 2026 && c.month == 3 && c.day == 16 && c.weekday == 2,
            """
            These tests assume TestClock.reference is locally Monday 16 March 2026; \
            here it is \(TestClock.iso(TestClock.reference)) → \(c). \
            Fix the assumption, not the flow.
            """,
            sourceLocation: sourceLocation
        )
    }

    @Test("CF-14 every fixture's commitments are extracted with their relative dates resolved")
    func extractionFindsCommitmentsWithDates() async throws {
        requireReferenceIsMonday16March()

        try await TestWorkspace.with { workspace in
            let store = try await workspace.store()
            try await seed(store: store, captures: Fixtures.all())

            let service = MemoryService(store: store, extractors: [RuleExtractor()])
            let touched = try await service.consolidate(
                since: TestClock.days(-1),
                now: TestClock.hours(1)
            )
            #expect(touched > 0, "consolidation over five realistic screens produced nothing")

            let commitments = try await store.entities(kind: .commitment, includeDeleted: false)
            #expect(commitments.count >= 10, "expected a commitment per promise in the fixtures")

            // Slack: "…deployed by Friday…" → Friday 20 March.
            let byFriday = try #require(
                commitments.firstTitled("deployed by Friday"),
                "the Slack promise with a Friday deadline was not extracted"
            )
            expectLocalDay(byFriday.dueAt, 2026, 3, 20, hour: 17, what: "\"by Friday\"")

            // Slack: "…tomorrow morning…" → Tuesday 17 March.
            let tomorrowMorning = try #require(
                commitments.firstTitled("migration notes tomorrow morning"),
                "the Slack promise due tomorrow morning was not extracted"
            )
            expectLocalDay(tomorrowMorning.dueAt, 2026, 3, 17, hour: 17, what: "\"tomorrow morning\"")

            // Slack: "…at the Thursday sync." → Thursday 19 March.
            let thursdaySync = try #require(
                commitments.firstTitled("walk through it together at the Thursday sync"),
                "the Slack proposal naming Thursday was not extracted"
            )
            expectLocalDay(thursdaySync.dueAt, 2026, 3, 19, hour: 17, what: "\"Thursday\"")

            // Email: "…agenda by Wednesday…" → Wednesday 18 March.
            let byWednesday = try #require(
                commitments.firstTitled("agenda by Wednesday"),
                "the emailed promise with a Wednesday deadline was not extracted"
            )
            expectLocalDay(byWednesday.dueAt, 2026, 3, 18, hour: 17, what: "\"by Wednesday\"")

            // Standup: "…hand it over by Thursday." → Thursday 19 March.
            let handOver = try #require(
                commitments.firstTitled("hand it over by Thursday"),
                "the standup hand-over commitment was not extracted"
            )
            expectLocalDay(handOver.dueAt, 2026, 3, 19, hour: 17, what: "standup \"by Thursday\"")

            // Standup: "I'll write the rollback runbook tomorrow." → Tuesday 17 March.
            let runbook = try #require(
                commitments.firstTitled("rollback runbook tomorrow"),
                "the standup runbook commitment was not extracted"
            )
            expectLocalDay(runbook.dueAt, 2026, 3, 17, hour: 17, what: "standup \"tomorrow\"")

            // Code review: "…push an update tomorrow." → Tuesday 17 March.
            let pushUpdate = try #require(
                commitments.firstTitled("push an update tomorrow"),
                "the review promise due tomorrow was not extracted"
            )
            expectLocalDay(pushUpdate.dueAt, 2026, 3, 17, hour: 17, what: "review \"tomorrow\"")

            // Code review: "…before the release cut on Friday." → Friday 20 March.
            let releaseCut = try #require(
                commitments.firstTitled("release cut on Friday"),
                "the review commitment tied to the Friday release cut was not extracted"
            )
            expectLocalDay(releaseCut.dueAt, 2026, 3, 20, hour: 17, what: "review \"on Friday\"")

            // Undated commitments stay undated. Inventing a deadline is as bad as missing one.
            let request = try #require(
                commitments.firstTitled("Can you also drop the migration notes"),
                "the Slack request was not extracted"
            )
            #expect(request.dueAt == nil, "a request with no date was given one: \(String(describing: request.dueAt))")

            let actionItem = try #require(
                commitments.firstTitled("Action item for you"),
                "the emailed action item was not extracted"
            )
            #expect(actionItem.dueAt == nil, "an action item with no date was given one")

            // Every resolved due date is in the working week after the reference Monday, which
            // is the whole point of resolving against the capture rather than "now".
            for commitment in commitments {
                guard let due = commitment.dueAt else { continue }
                #expect(
                    due >= TestClock.reference && due <= TestClock.days(7),
                    "\(TestClock.iso(due)) is outside the week after the capture: \(commitment.title)"
                )
            }

            assertNoNetwork()
            await store.close()
        }
    }

    @Test("CF-14 shell noise produces no commitments and no entities at all")
    func terminalNoiseInventsNothing() async throws {
        // On its own: the negative control. Build output, a test summary, a directory
        // listing and an exit code must not become memory.
        let alone = try await RuleExtractor().extract(from: [Fixtures.terminalSession()])
        #expect(
            alone.entities.isEmpty,
            "terminal noise invented \(alone.entities.map { "\($0.kind.rawValue)/\($0.title)" })"
        )
        #expect(alone.provenance.isEmpty)

        // And in company: when it sits in a batch beside five screens that *do* carry
        // meaning, nothing may be attributed to it either.
        try await TestWorkspace.with { workspace in
            let store = try await workspace.store()
            let captures = Fixtures.all()
            try await seed(store: store, captures: captures)
            let terminalID = try #require(
                captures.first { $0.appName == "Terminal" }?.id
            )

            let service = MemoryService(store: store, extractors: [RuleExtractor()])
            try await service.consolidate(since: TestClock.days(-1), now: TestClock.hours(1))

            let entities = try await store.entities(kind: nil, includeDeleted: true)
            #expect(!entities.isEmpty, "the other four fixtures should still have produced entities")

            for entity in entities {
                let rows = try await store.provenance(entityID: entity.id)
                #expect(
                    !rows.contains { $0.captureID == terminalID },
                    "\(entity.kind.rawValue) \"\(entity.title)\" was traced to the terminal capture"
                )
            }

            // Nothing that only exists in the shell output may appear as a title anywhere.
            let noise = ["swift build", "Build complete", "drwxr-xr-x", ".DS_Store", "Executed 41", "612M"]
            for entity in entities {
                for token in noise {
                    #expect(
                        !entity.title.contains(token),
                        "shell text \"\(token)\" became a \(entity.kind.rawValue): \(entity.title)"
                    )
                }
            }

            assertNoNetwork()
            await store.close()
        }
    }

    @Test("CF-14 relative dates follow the capture's timestamp, not the wall clock")
    func relativeDatesFollowTheCapture() async throws {
        requireReferenceIsMonday16March()
        let extractor = RuleExtractor()

        // The same words, captured on three different Mondays. "by Friday" must mean a
        // different Friday each time. A wall-clock implementation would return the same
        // date for all three, and would change its answer tomorrow.
        let cases: [(shift: Double, year: Int, month: Int, day: Int)] = [
            (0, 2026, 3, 20),      // captured Mon 16 Mar → Fri 20 Mar
            (7, 2026, 3, 27),      // captured Mon 23 Mar → Fri 27 Mar
            (-35, 2026, 2, 13),    // captured Mon  9 Feb → Fri 13 Feb
        ]

        for testCase in cases {
            let capturedAt = TestClock.days(testCase.shift)
            let result = try await extractor.extract(from: [Fixtures.slackThread(at: capturedAt)])
            let commitments = result.entities.filter { $0.kind == .commitment }

            let friday = try #require(
                commitments.firstTitled("deployed by Friday"),
                "the Friday commitment vanished at shift \(testCase.shift)"
            )
            expectLocalDay(
                friday.dueAt, testCase.year, testCase.month, testCase.day, hour: 17,
                what: "\"by Friday\" captured at \(TestClock.iso(capturedAt))"
            )

            // "tomorrow" is the day after the capture, whichever day that is.
            let tomorrow = try #require(
                commitments.firstTitled("migration notes tomorrow morning"),
                "the tomorrow commitment vanished at shift \(testCase.shift)"
            )
            let due = try #require(tomorrow.dueAt)
            #expect(
                TestClock.sameLocalDay(due, TestClock.days(testCase.shift + 1)),
                "\"tomorrow\" from \(TestClock.iso(capturedAt)) resolved to \(TestClock.iso(due))"
            )
        }

        assertNoNetwork()
    }

    // MARK: - CF-15 · Every entity is traceable

    @Test("CF-15 every entity has provenance whose snippet literally occurs in its capture")
    func everyEntityIsTraceable() async throws {
        try await TestWorkspace.with { workspace in
            let store = try await workspace.store()
            let captures = Fixtures.all()
            try await seed(store: store, captures: captures)

            let service = MemoryService(store: store, extractors: [RuleExtractor()])
            try await service.consolidate(since: TestClock.days(-1), now: TestClock.hours(1))

            let entities = try await store.entities(kind: nil, includeDeleted: true)
            #expect(entities.count >= 20, "too few entities for this to prove anything")

            var totalRows = 0
            for entity in entities {
                let rows = try await store.provenance(entityID: entity.id)
                totalRows += rows.count

                // The law: nothing enters memory without a pointer to where it came from.
                #expect(
                    !rows.isEmpty,
                    "\(entity.kind.rawValue) \"\(entity.title)\" has no provenance at all"
                )

                var grounded = 0
                for row in rows {
                    #expect(row.entityID == entity.id)

                    // The capture ID must resolve to a real row, not a dangling reference.
                    let capture = try await store.capture(id: row.captureID)
                    let source = try #require(
                        capture,
                        "\(entity.title) cites capture \(row.captureID), which is not in the store"
                    )

                    // And the snippet must be text that was genuinely on that screen. The
                    // haystack is the window title plus the body, because that is exactly what
                    // the extractor read and both are fields of this capture row.
                    let haystack = capturedText(of: source)
                    let needle = literalSnippet(row)
                    #expect(
                        !needle.isEmpty,
                        "\(entity.title) has an empty snippet for field \(row.field)"
                    )
                    if haystack.contains(needle) {
                        grounded += 1
                    } else {
                        Issue.record(
                            """
                            \(entity.kind.rawValue) "\(entity.title)" field \(row.field) cites text \
                            that is not in capture \(row.captureID) (\(source.appName)):
                              snippet: \(needle)
                            """
                        )
                    }
                }

                #expect(
                    grounded >= 1,
                    "\(entity.kind.rawValue) \"\(entity.title)\" has no snippet that occurs in its source"
                )
            }

            #expect(totalRows > entities.count, "expected more provenance rows than entities")
            assertNoNetwork()
            await store.close()
        }
    }

    @Test("CF-15 a named person traces to the exact capture and words that named them")
    func provenancePointsAtTheRightCapture() async throws {
        try await TestWorkspace.with { workspace in
            let store = try await workspace.store()
            let captures = Fixtures.all()
            try await seed(store: store, captures: captures)
            let email = try #require(captures.first { $0.appName == "Mail" })
            let standup = try #require(captures.first { $0.appName == "Notes" })

            let service = MemoryService(store: store, extractors: [RuleExtractor()])
            try await service.consolidate(since: TestClock.days(-1), now: TestClock.hours(1))

            // "To: Marco Bianchi" appears in exactly one of the five screens.
            let people = try await store.entities(kind: .person, includeDeleted: false)
            let marco = try #require(
                people.first { $0.title == "Marco Bianchi" },
                "expected the email header to produce Marco Bianchi, got \(people.map(\.title))"
            )
            let marcoRows = try await store.provenance(entityID: marco.id)
            #expect(marcoRows.allSatisfy { $0.captureID == email.id })
            #expect(
                marcoRows.contains { $0.snippet.contains("Marco Bianchi") },
                "no snippet actually contains the name: \(marcoRows.map(\.snippet))"
            )

            // ACME-412 is mentioned in two different screens, so the one entity must carry
            // provenance from both. This is what makes memory explainable rather than
            // merely plausible.
            let projects = try await store.entities(kind: .project, includeDeleted: false)
            let ticket = try #require(
                projects.first { $0.title == "ACME-412" },
                "expected ACME-412, got \(projects.map(\.title))"
            )
            let ticketRows = try await store.provenance(entityID: ticket.id)
            let sources = Set(ticketRows.map(\.captureID))
            #expect(
                sources.count >= 2,
                "ACME-412 appears in the standup and the review but cites \(sources.count) capture(s)"
            )
            #expect(sources.contains(standup.id))
            for row in ticketRows {
                let source = try #require(try await store.capture(id: row.captureID))
                #expect(capturedText(of: source).contains(literalSnippet(row)))
            }

            assertNoNetwork()
            await store.close()
        }
    }

    // MARK: - CF-16 · Consolidation is idempotent

    @Test("CF-16 consolidating three times over the same captures creates no duplicates")
    func consolidationIsIdempotent() async throws {
        try await TestWorkspace.with { workspace in
            let store = try await workspace.store()
            try await seed(store: store, captures: Fixtures.all())

            // The rule pass with the model pass layered on top, which is the real
            // configuration. The stub returns "[]" (a valid, empty extraction), so it
            // contributes nothing and cannot mask a duplicate coming from the rules.
            let brain = StubBrain(completionText: "[]")
            let service = MemoryService(
                store: store,
                // Guided generation off: this flow counts calls into `brain` and asserts that
                // three consolidations produce identical entities. The on-device guided path
                // answers before the brain and varies run to run, so leaving it on would test
                // Apple's model rather than this pipeline, and would pass or fail depending
                // on whether the machine has Apple Intelligence.
                extractors: [RuleExtractor(), LLMExtractor(brain: brain, useGuidedGeneration: false)]
            )

            struct Snapshot: Equatable {
                var entityCount = 0
                var provenanceCount = 0
                var titles: Set<String> = []
                var dueDates: [String: Date] = [:]
            }

            func snapshot() async throws -> Snapshot {
                let entities = try await store.entities(kind: nil, includeDeleted: true)
                var out = Snapshot()
                out.entityCount = entities.count
                for entity in entities {
                    out.titles.insert("\(entity.kind.rawValue)|\(entity.title)")
                    if let due = entity.dueAt { out.dueDates["\(entity.kind.rawValue)|\(entity.title)"] = due }
                    out.provenanceCount += try await store.provenance(entityID: entity.id).count
                }
                return out
            }

            var snapshots: [Snapshot] = []
            for _ in 1...3 {
                // The same window, the same injected instant: only re-processing differs.
                try await service.consolidate(since: TestClock.days(-1), now: TestClock.hours(1))
                snapshots.append(try await snapshot())
            }

            let first = snapshots[0]
            #expect(first.entityCount > 0, "nothing was extracted, so idempotence is vacuous")

            // The flow's pass condition: identical counts after runs 2 and 3.
            #expect(
                snapshots[1].entityCount == snapshots[2].entityCount,
                "entity count moved between run 2 (\(snapshots[1].entityCount)) and run 3 (\(snapshots[2].entityCount))"
            )
            // Stronger, and true of this implementation: nothing new appears after run 1 either.
            #expect(
                first.entityCount == snapshots[1].entityCount,
                "run 2 changed the entity count from \(first.entityCount) to \(snapshots[1].entityCount)"
            )
            #expect(first.titles == snapshots[1].titles)
            #expect(snapshots[1].titles == snapshots[2].titles)

            // Provenance is keyed by content, so re-reading the same text must not pile up rows.
            #expect(
                snapshots[1].provenanceCount == snapshots[2].provenanceCount,
                "provenance grew from \(snapshots[1].provenanceCount) to \(snapshots[2].provenanceCount) on run 3"
            )
            #expect(first.provenanceCount == snapshots[1].provenanceCount)

            // A re-run must not move a date that was already resolved.
            #expect(first.dueDates == snapshots[1].dueDates)
            #expect(snapshots[1].dueDates == snapshots[2].dueDates)

            // No two surviving entities share a dedupe key: that is what "no duplicates" means.
            let entities = try await store.entities(kind: nil, includeDeleted: true)
            let keys = entities.map { MemoryText.dedupeKey(kind: $0.kind, title: $0.title) }
            #expect(
                Set(keys).count == keys.count,
                "duplicate dedupe keys: \(keys.filter { key in keys.filter { $0 == key }.count > 1 })"
            )

            // The model pass really did run on every consolidation; it just found nothing.
            #expect(brain.completeCallCount == 3, "the LLM extractor was not exercised")
            assertNoNetwork()
            await store.close()
        }
    }

    // MARK: - CF-19 · Context stays within budget

    @Test("CF-19 a 2,000 token packet over 500 entities and 5,000 captures stays in budget")
    func contextStaysWithinBudget() async throws {
        try await TestWorkspace.with { workspace in
            let store = try await workspace.store()

            // 5 000 captures across ten days. The density matters: the packet builder reads
            // the last twelve hours, so this leaves far more recent material than the budget
            // can hold and the ceiling is genuinely under pressure rather than never reached.
            let captures = makeCaptures(count: 5_000, spanningDays: 10, from: TestClock.days(-10))

            // 500 entities, every fiftieth pinned, commitments due across the fortnight after
            // the reference, plus three markers that make the selection rule observable.
            var entities = makeEntities(count: 500, from: TestClock.reference, pinnedEvery: 50)
            let pinnedMarker = makeEntity(
                kind: .note, title: "Pinned marker for the budget flow", pinned: true
            )
            let urgentMarker = makeEntity(
                kind: .commitment, title: "Urgent marker commitment for the budget flow",
                dueAt: TestClock.hours(-1)
            )
            let distantMarker = makeEntity(
                kind: .commitment, title: "Distant marker commitment for the budget flow",
                dueAt: TestClock.days(400)
            )
            entities.append(contentsOf: [pinnedMarker, urgentMarker, distantMarker])

            try await seed(store: store, captures: captures, entities: entities)
            let stats = try await store.stats()
            #expect(stats.captureCount == 5_000)
            #expect(stats.entityCount == 503)

            let service = MemoryService(store: store, extractors: [])
            let started = ContinuousClock.now
            let packet = try await service.context(
                for: "what do I owe anyone this week",
                budget: 2_000,
                now: TestClock.reference
            )
            let elapsed = started.duration(to: .now)

            // 1. The budget is a hard ceiling, in both the units it is expressed in.
            #expect(
                packet.approxTokens <= 2_000,
                "packet estimated \(packet.approxTokens) tokens against a 2 000 token budget"
            )
            #expect(
                packet.summary.count <= 8_000,
                "packet rendered \(packet.summary.count) characters against an 8 000 character ceiling"
            )
            #expect(packet.approxTokens == packet.summary.count / 4)

            // 2. It is not trivially small: a packet that fits by being empty is useless.
            #expect(packet.approxTokens >= 1_500, "the packet barely used its budget")
            #expect(!packet.captureIDs.isEmpty)

            // 3. Pinned entities are present: all eleven of them.
            let selected = Set(packet.entityIDs)
            for pinned in entities.filter(\.pinned) {
                #expect(
                    selected.contains(pinned.id),
                    "pinned entity \"\(pinned.title)\" was dropped from the packet"
                )
            }
            #expect(packet.summary.contains("Pinned marker for the budget flow"))

            // 4. Due-soon and overdue commitments are present, and the far-future one is not:
            //    twelve slots, spent on urgency rather than on insertion order.
            #expect(
                selected.contains(urgentMarker.id),
                "the overdue commitment did not make it into the packet"
            )
            #expect(packet.summary.contains("(OVERDUE)"))
            #expect(
                !selected.contains(distantMarker.id),
                "a commitment due in 400 days crowded out the urgent ones"
            )

            let byID = Dictionary(uniqueKeysWithValues: entities.map { ($0.id, $0) })
            let dueSoon = packet.entityIDs
                .compactMap { byID[$0] }
                .filter { entity in
                    guard entity.kind == .commitment, let due = entity.dueAt else { return false }
                    return due >= TestClock.reference && due <= TestClock.days(7)
                }
            #expect(
                dueSoon.count >= 5,
                "only \(dueSoon.count) commitments due within the week made the packet"
            )

            // 5. Every cited capture resolves to a real row.
            for id in packet.captureIDs.prefix(25) {
                let row = try await store.capture(id: id)
                #expect(row != nil, "packet cited unknown capture \(id)")
            }

            // 6. And it is fast. Measured at roughly 3 ms, so this ceiling is three orders of
            //    magnitude of headroom: it catches a pathological regression (an N² scan, a
            //    per-entity round trip) without ever flaking on a loaded machine.
            #expect(
                elapsed < .seconds(5),
                "building a 2 000 token packet took \(elapsed)"
            )

            assertNoNetwork()
            await store.close()
        }
    }

    @Test("CF-19 the token budget is a hard ceiling at every size")
    func budgetHoldsAtEverySize() async throws {
        // Regression guard. The renderer joins sections with "\n\n" and prefixes the recent
        // section with a header; when neither was charged against the budget, a 1 000 token
        // request produced 4 007 characters (1 001 tokens). Nothing may be free.
        try await TestWorkspace.with { workspace in
            let store = try await workspace.store()
            let captures = makeCaptures(count: 400, spanningDays: 1, from: TestClock.days(-1))
            let entities = makeEntities(count: 120, from: TestClock.reference, pinnedEvery: 10)
            try await seed(store: store, captures: captures, entities: entities)

            let service = MemoryService(store: store, extractors: [])
            for budget in [100, 250, 500, 750, 1_000, 1_250, 1_500, 1_750, 2_000, 3_000] {
                let packet = try await service.context(
                    for: "open commitments and pinned notes",
                    budget: budget,
                    now: TestClock.reference
                )
                #expect(
                    packet.summary.count <= budget * 4,
                    "budget \(budget) rendered \(packet.summary.count) characters, ceiling \(budget * 4)"
                )
                #expect(
                    packet.approxTokens <= budget,
                    "budget \(budget) estimated \(packet.approxTokens) tokens"
                )
            }

            assertNoNetwork()
            await store.close()
        }
    }
}

// MARK: - Local helpers

extension MemoryPipelineTests {

    /// Asserts that `date` falls on the given **local** calendar day, at the given local hour.
    ///
    /// Day-granularity expressions resolve to 17:00 local, which is Memoir's convention for "the
    /// end of that working day"; the hour is asserted so a silent change of convention shows up
    /// here rather than as a missed nudge.
    fileprivate func expectLocalDay(
        _ date: Date?,
        _ year: Int,
        _ month: Int,
        _ day: Int,
        hour: Int,
        what: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        guard let date else {
            Issue.record("\(what) resolved to no date at all", sourceLocation: sourceLocation)
            return
        }
        let c = TestClock.localCalendar.dateComponents([.year, .month, .day, .hour], from: date)
        #expect(
            c.year == year && c.month == month && c.day == day && c.hour == hour,
            """
            \(what) resolved to \(TestClock.iso(date)) \
            (local \(c.year ?? 0)-\(c.month ?? 0)-\(c.day ?? 0) \(c.hour ?? 0):00), \
            expected \(year)-\(month)-\(day) \(hour):00 local
            """,
            sourceLocation: sourceLocation
        )
    }
}

/// Everything that was on screen for this capture, whitespace-collapsed: the window title
/// and the body, which is exactly the text the extractor scanned and both of which are
/// fields of the capture row.
private func capturedText(of capture: CaptureEvent) -> String {
    MemoryText.collapseWhitespace(RuleExtractor.scannableText(for: capture))
}

/// The part of a provenance snippet that must occur verbatim in its capture.
///
/// Two decorations are stripped, both added after the text was read rather than found in it:
/// a trailing ` […]` annotation (the resolved due date, or the marker `resolved`) and the
/// ellipsis marking a truncation. What is left is a literal run of captured text.
private func literalSnippet(_ row: Provenance) -> String {
    var out = row.snippet
    if let bracket = out.range(of: " \\[[^\\[\\]]*\\]$", options: .regularExpression) {
        out.removeSubrange(bracket)
    }
    if out.hasSuffix("\u{2026}") { out.removeLast() }
    return out
}

extension Array where Element == Entity {

    /// The first entity whose title contains `needle`, case-insensitively and locale-independently.
    fileprivate func firstTitled(_ needle: String) -> Entity? {
        let lowered = needle.lowercased()
        return first { $0.title.lowercased().contains(lowered) }
    }
}
