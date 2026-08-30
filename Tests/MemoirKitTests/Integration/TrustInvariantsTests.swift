//
//  TrustInvariantsTests.swift
//  CF-1 … CF-7: Tier 0.
//
//  ─────────────────────────────────────────────────────────────────────────────
//  These seven flows are the promises Memoir makes to the person running it. If any
//  of them breaks the product is not shippable, so every test here is written to
//  fail loudly and to name the promise it caught breaking.
//  ─────────────────────────────────────────────────────────────────────────────
//
//  All of them run against a real `Store` on a real SQLite file inside a throwaway
//  workspace, with `Paths` redirected, the network blocked and every date injected.
//  See `TestSupport.swift` for the harness.
//

import Foundation
import SQLite3
import Testing

import MemoirFixtures
@testable import MemoirKit

// MARK: - A note on the on-device model
//
// `AppleOnDeviceBrain` is a client of FoundationModels, which runs the model in a **separate
// process**. Two consequences shape every brain test in this file.
//
// 1. It is the one boundary the brief says to fake. A `URLProtocol` installed in the test
//    process cannot observe what an XPC service does, so generating through it would add no
//    evidence at all to CF-2 while adding a dependency on someone else's daemon.
// 2. It is not stable enough to sit under a Tier 0 flow. Measured on this machine: six runs of
//    the CF-2 and CF-3 suites while they generated through the on-device model took 24 to 55
//    seconds each and one of the six died with `SIGTRAP` raised inside FoundationModels'
//    guardrail path (`NLLanguageRecognizer processString:`), taking the whole test process with
//    it. A trap is not catchable, so `BrainRouter` cannot fall back from it either.
//
// So the routing claim is proved rather than sampled. `chain()` is the set of brains
// `answer(question:context:)` will try, in order; if it contains no cloud kind then no cloud
// brain can possibly answer, whatever the environment does. On top of that each flow performs
// one real end-to-end `answer(...)` with the chain arranged so the brain that runs is
// `RulesOnlyBrain`: in-process, store-backed and therefore actually observable.

/// Runs one real `answer(...)` through the router with the chain arranged so `RulesOnlyBrain`
/// is reached first, and returns it.
///
/// `chain()` is `[preferred, appleOnDevice, rulesOnly]` with duplicates dropped, and `answer`
/// walks it in order, so preferring `rulesOnly` puts it at the head and the on-device model is
/// never reached. The cloud-blocking assertions are made against the *original* preference by
/// the caller, before this is called.
private func localAnswer(
    from router: BrainRouter,
    question: String,
    context: ContextPacket
) async throws -> BrainAnswer {
    await router.setPreferred(.rulesOnly)
    let chain = await router.chain()
    #expect(chain.first == .rulesOnly, "the answer would have gone through the on-device model: \(chain)")
    return try await router.answer(question: question, context: context)
}

// MARK: - CF-1 · A user correction is permanent

/// *The single most important invariant in the product.*
///
/// A memory that quietly reverts a correction is worse than no memory at all, so this is
/// attacked from six directions:
///
/// 1. five consecutive consolidation passes over the same source text, each one more
///    confident than the last;
/// 2. a hostile extraction result carrying the *same entity id* and a different title;
/// 3. re-observing the user's own corrected wording, which is the case where the extractor
///    and the correction agree on the dedupe key and a naive merge would overwrite;
/// 4. a spelling variant that normalises to the same dedupe key, which must not fork the row;
/// 5. **fields the user deliberately emptied**, which is the only place the `corrected` flag
///    is the sole line of defence (see ``clearedFieldsAreNotRefilled()``);
/// 6. a correction followed by a deletion, re-observed repeatedly.
@Suite("CF-1 corrections are permanent")
struct CF1CorrectionPermanenceTests {

    /// Everything after the first consolidation: the store, the entity the fixture is built
    /// around, and the corrected form of it.
    private struct Corrected {
        let store: Store
        let entityID: ID
        let originalTitle: String
        let originalDueAt: Date?
        let correctedTitle: String
        let correctedDetail: String
        let confidenceAtCorrection: Double
    }

    /// Seeds the Slack fixture, consolidates once, and applies a user correction to the
    /// "…by Friday" commitment. Returns everything the assertions need.
    private func correctedCommitment(in ws: TestWorkspace) async throws -> Corrected {
        let store = try await ws.store()
        try await seed(store: store, captures: [Fixtures.slackThread(at: TestClock.reference)])

        let service = MemoryService(store: store, extractors: [RuleExtractor()])
        let touched = try await service.consolidate(since: TestClock.hours(-1), now: TestClock.reference)
        #expect(touched > 0, "the fixture must produce entities or there is nothing to correct")

        let commitments = try await store.entities(kind: .commitment, includeDeleted: false)
        let original = try #require(
            commitments.first { $0.dueAt != nil && $0.title.lowercased().contains("friday") },
            "the Slack fixture must yield a dated 'by Friday' commitment"
        )
        #expect(!original.corrected, "a freshly extracted entity is not a correction")

        let correctedTitle = "Ship the shared retry budget before the Friday QA build"
        let correctedDetail = "Edited by the user in the memory browser."
        var edited = original
        edited.title = correctedTitle
        edited.detail = correctedDetail
        edited.corrected = true
        edited.updatedAt = TestClock.hours(2)
        try await store.upsert(entity: edited)

        return Corrected(
            store: store,
            entityID: original.id,
            originalTitle: original.title,
            originalDueAt: original.dueAt,
            correctedTitle: correctedTitle,
            correctedDetail: correctedDetail,
            confidenceAtCorrection: original.confidence
        )
    }

    /// Deleting something yourself is a correction, and for a long time it did not say so.
    ///
    /// `PortraitModel.dismiss` ("Not a person") and `MemoryBrowserModel.delete` both called
    /// `deleteEntity(id:)`, which wrote `deleted = 1` and nothing else — byte-identical to
    /// what the three consolidation sweeps in `MemoryService` write. The cost showed up the
    /// first time anyone asked how often this user corrects their memory: `sum(corrected)`
    /// was 0 across all 1,533 entities on a 75-day-old installation, and there was no way to
    /// tell whether that meant "never corrected anything" or "corrected things, in a way the
    /// database does not record".
    ///
    /// It is not only bookkeeping. The resurrection guard in `MemoryMerge.merged` reads
    /// `corrected`, so a row the user retired by hand was protected only by `deleted`, while
    /// a row they retired *and* edited was protected by both.
    @Test("CF-1 a delete the user performs is marked as theirs; a sweep's is not")
    func userInitiatedDeleteIsRecordedAsACorrection() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()

            let byHand = Entity(kind: .person, title: "Vector Art", source: .inferred)
            let bySweep = Entity(kind: .person, title: "Product Manager", source: .inferred)
            try await store.upsert(entity: byHand)
            try await store.upsert(entity: bySweep)

            // What the two UI paths do.
            try await store.deleteEntity(id: byHand.id, corrected: true)
            // What the three consolidation sweeps do.
            try await store.deleteEntity(id: bySweep.id)

            let handRow = try #require(try await store.entity(id: byHand.id))
            let sweepRow = try #require(try await store.entity(id: bySweep.id))

            #expect(handRow.deleted, "the user's delete did not take")
            #expect(handRow.corrected, "the user's own judgement was not recorded as theirs")
            #expect(sweepRow.deleted, "the sweep's delete did not take")
            #expect(!sweepRow.corrected, "a sweep must not claim to be the user")
        }
    }

    /// The flag is one-way. A sweep retiring something the user already ruled on must not
    /// quietly downgrade the ruling to a machine's.
    @Test("CF-1 a later sweep delete never clears a correction the user already made")
    func sweepDeleteDoesNotClearAnExistingCorrection() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()

            let entity = Entity(kind: .person, title: "Apple Intelligence", source: .inferred)
            try await store.upsert(entity: entity)

            try await store.deleteEntity(id: entity.id, corrected: true)
            try await store.deleteEntity(id: entity.id)

            let row = try #require(try await store.entity(id: entity.id))
            #expect(row.corrected, "a sweep overwrote the user's judgement with its own")
        }
    }

    @Test("CF-1 a corrected title survives five consecutive, progressively more confident passes")
    func correctionSurvivesFiveHigherConfidencePasses() async throws {
        try await TestWorkspace.with { ws in
            let fixture = try await correctedCommitment(in: ws)
            let store = fixture.store

            let entitiesAfterCorrection = try await store.entities(kind: nil, includeDeleted: true)
            let countAfterCorrection = entitiesAfterCorrection.count

            var previousConfidence = fixture.confidenceAtCorrection

            for pass in 1...5 {
                // Each pass re-reads the same capture and proposes the same entity with a
                // higher confidence, a different detail and a different due date. Only the
                // confidence may be allowed through.
                let aggressive = RewritingExtractor(
                    base: RuleExtractor(),
                    confidence: 0.55 + Double(pass) * 0.08,
                    detail: "Rewritten by extraction pass \(pass)",
                    dueAt: TestClock.days(Double(40 + pass))
                )
                let service = MemoryService(store: store, extractors: [aggressive])
                _ = try await service.consolidate(
                    since: TestClock.hours(-1),
                    now: TestClock.days(Double(pass))
                )

                let after = try #require(try await store.entity(id: fixture.entityID))

                #expect(
                    after.title == fixture.correctedTitle,
                    "pass \(pass) overwrote the user's title with \"\(after.title)\""
                )
                #expect(after.corrected, "pass \(pass) cleared the corrected flag")
                #expect(
                    after.detail == fixture.correctedDetail,
                    "pass \(pass) overwrote the user's detail with \"\(after.detail ?? "nil")\""
                )
                #expect(after.dueAt == fixture.originalDueAt, "pass \(pass) moved the due date")
                #expect(after.kind == .commitment, "pass \(pass) changed the kind")
                #expect(!after.deleted, "pass \(pass) deleted the entity")
                #expect(
                    after.confidence >= previousConfidence,
                    "pass \(pass) lowered confidence from \(previousConfidence) to \(after.confidence)"
                )
                previousConfidence = after.confidence

                // No shadow copy under the pre-correction wording.
                let live = try await store.entities(kind: nil, includeDeleted: true)
                #expect(
                    live.count == countAfterCorrection,
                    "pass \(pass) created \(live.count - countAfterCorrection) new entities"
                )
                #expect(
                    !live.contains { $0.id != fixture.entityID && $0.title == fixture.originalTitle },
                    "pass \(pass) resurrected the original title as a second entity"
                )
            }

            #expect(
                previousConfidence > fixture.confidenceAtCorrection,
                "corroboration must still be allowed to raise confidence"
            )
            assertNoNetwork()
        }
    }

    @Test("CF-1 an extraction result carrying the same id and a different title cannot rewrite it")
    func correctionSurvivesAnIdCollision() async throws {
        try await TestWorkspace.with { ws in
            let fixture = try await correctedCommitment(in: ws)
            let store = fixture.store
            let service = MemoryService(store: store, extractors: [])

            // The nastiest shape there is: an extractor that resolves to the very same row and
            // asks for a completely different title at maximum confidence.
            let hostile = Entity(
                id: fixture.entityID,
                kind: .commitment,
                title: "Deploy the rate limiter on Friday, per the extractor",
                detail: "Model rewrite",
                dueAt: TestClock.days(99),
                confidence: 0.99,
                pinned: true,
                corrected: false,
                deleted: false,
                createdAt: TestClock.reference,
                updatedAt: TestClock.days(3)
            )
            _ = try await service.commit(
                ExtractionResult(entities: [hostile], provenance: []),
                now: TestClock.days(3)
            )

            let after = try #require(try await store.entity(id: fixture.entityID))
            #expect(after.title == fixture.correctedTitle)
            #expect(after.detail == fixture.correctedDetail)
            #expect(after.dueAt == fixture.originalDueAt)
            #expect(after.corrected)
            #expect(!after.pinned, "extraction must not be able to pin an entity either")

            let all = try await store.entities(kind: nil, includeDeleted: true)
            #expect(all.filter { $0.id == fixture.entityID }.count == 1)
        }
    }

    @Test("CF-1 re-observing the user's own corrected wording does not overwrite it")
    func correctionSurvivesBeingReObserved() async throws {
        try await TestWorkspace.with { ws in
            let fixture = try await correctedCommitment(in: ws)
            let store = fixture.store
            let service = MemoryService(store: store, extractors: [])

            // The correction itself appears on screen and is extracted afresh: same normalised
            // title, so the dedupe key matches and a naive merge would write straight through.
            let echo = Entity(
                id: MemoryText.stableID(
                    "entity",
                    EntityKind.commitment.rawValue,
                    MemoryText.normalizedTitle(fixture.correctedTitle)
                ),
                kind: .commitment,
                title: fixture.correctedTitle.uppercased(),
                detail: "Seen again in Slack",
                dueAt: TestClock.days(77),
                confidence: 0.95,
                createdAt: TestClock.days(4),
                updatedAt: TestClock.days(4)
            )
            _ = try await service.commit(
                ExtractionResult(entities: [echo], provenance: []),
                now: TestClock.days(4)
            )

            let after = try #require(try await store.entity(id: fixture.entityID))
            #expect(after.title == fixture.correctedTitle, "the user's capitalisation was overwritten")
            #expect(after.detail == fixture.correctedDetail)
            #expect(after.dueAt == fixture.originalDueAt)
            #expect(after.corrected)

            let commitments = try await store.entities(kind: .commitment, includeDeleted: true)
            let matching = commitments.filter {
                MemoryText.normalizedTitle($0.title) == MemoryText.normalizedTitle(fixture.correctedTitle)
            }
            #expect(matching.count == 1, "the corrected entity was duplicated under its own title")
        }
    }

    @Test("CF-1 a corrected entity is not duplicated under a slightly different normalised title")
    func correctionIsNotDuplicatedByANormalisationVariant() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()

            // One short, controlled commitment, so the assertion is about normalisation and
            // nothing else.
            let first = Fixtures.capture(
                text: "I'll ship the shared retry budget by Friday.",
                app: "Slack",
                bundleID: "com.tinyspeck.slackmacgap",
                windowTitle: nil,
                at: TestClock.reference,
                name: "cf1-variant-a"
            )
            try await seed(store: store, captures: [first])

            let service = MemoryService(store: store, extractors: [RuleExtractor()])
            _ = try await service.consolidate(since: TestClock.hours(-1), now: TestClock.reference)

            let commitments = try await store.entities(kind: .commitment, includeDeleted: true)
            #expect(commitments.count == 1, "expected exactly one commitment from one sentence")
            let original = try #require(commitments.first)

            var edited = original
            edited.title = "Shared retry budget moves into Redis"
            edited.corrected = true
            edited.updatedAt = TestClock.hours(1)
            try await store.upsert(entity: edited)

            // The same sentence again, differing only in case and punctuation, which is
            // exactly what `normalizedTitle` folds away, so it resolves to the same entity.
            let variantText = "i'll ship the shared RETRY budget by friday!!!"
            #expect(
                MemoryText.normalizedTitle(variantText) == MemoryText.normalizedTitle(first.text),
                "the two spellings must normalise identically or this test proves nothing"
            )
            let second = Fixtures.capture(
                text: variantText,
                app: "Slack",
                bundleID: "com.tinyspeck.slackmacgap",
                windowTitle: nil,
                at: TestClock.minutes(30),
                name: "cf1-variant-b"
            )
            try await seed(store: store, captures: [second])
            #expect(second.textHash != first.textHash, "the variant must be a genuinely new capture row")

            _ = try await service.consolidate(since: TestClock.hours(-1), now: TestClock.hours(2))

            let after = try await store.entities(kind: .commitment, includeDeleted: true)
            #expect(after.count == 1, "the variant spawned a duplicate commitment: \(after.map(\.title))")
            let survivor = try #require(after.first)
            #expect(survivor.id == original.id)
            #expect(survivor.title == "Shared retry budget moves into Redis")
            #expect(survivor.corrected)
        }
    }

    /// The decisive one.
    ///
    /// `MemoryMerge` protects a title unconditionally (the first observed spelling wins for
    /// every entity, corrected or not), so a test that only watches the title passes even with
    /// the `corrected` check deleted. The flag is the *only* thing standing between extraction
    /// and a field the user deliberately emptied, so that is what this pins: a cleared due date
    /// and a cleared detail must stay cleared, while an identical but uncorrected entity gets
    /// both filled in from the very same pass.
    @Test("CF-1 fields the user deliberately cleared are never refilled by extraction")
    func clearedFieldsAreNotRefilled() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            try await seed(store: store, captures: [Fixtures.slackThread(at: TestClock.reference)])

            let service = MemoryService(store: store, extractors: [RuleExtractor()])
            _ = try await service.consolidate(since: TestClock.hours(-1), now: TestClock.reference)

            let commitments = try await store.entities(kind: .commitment, includeDeleted: false)
            let subject = try #require(commitments.first { $0.dueAt != nil && $0.title.lowercased().contains("friday") })
            let control = try #require(commitments.first { $0.id != subject.id })

            // The user edits one of them and empties both fields. The other is left alone but
            // emptied the same way, so the two differ only in `corrected`.
            var corrected = subject
            corrected.title = "Ship the shared retry budget"
            corrected.detail = nil
            corrected.dueAt = nil
            corrected.corrected = true
            corrected.updatedAt = TestClock.hours(1)
            try await store.upsert(entity: corrected)

            var untouched = control
            untouched.detail = nil
            untouched.dueAt = nil
            untouched.corrected = false
            untouched.updatedAt = TestClock.hours(1)
            try await store.upsert(entity: untouched)

            let proposedDueAt = TestClock.days(45)
            for pass in 1...5 {
                let aggressive = RewritingExtractor(
                    base: RuleExtractor(),
                    confidence: 0.55 + Double(pass) * 0.08,
                    detail: "Supplied by extraction pass \(pass)",
                    dueAt: proposedDueAt
                )
                _ = try await MemoryService(store: store, extractors: [aggressive]).consolidate(
                    since: TestClock.hours(-1),
                    now: TestClock.days(Double(pass))
                )

                let after = try #require(try await store.entity(id: subject.id))
                #expect(after.dueAt == nil, "pass \(pass) put a due date back on a corrected entity")
                #expect(after.detail == nil, "pass \(pass) refilled a detail the user had cleared")
                #expect(after.title == "Ship the shared retry budget")
                #expect(after.corrected)
            }

            // The control proves the extractor really was offering both fields, so the five
            // assertions above are about the `corrected` flag and nothing else.
            let filled = try #require(try await store.entity(id: control.id))
            #expect(filled.dueAt == proposedDueAt, "the merge never offered a due date, so the test proved nothing")
            #expect(filled.detail?.hasPrefix("Supplied by extraction pass") == true, "the merge never offered a detail")
            #expect(!filled.corrected)
        }
    }

    @Test("CF-1 a corrected entity that is then deleted stays deleted through later consolidation")
    func correctedThenDeletedStaysDeleted() async throws {
        try await TestWorkspace.with { ws in
            let fixture = try await correctedCommitment(in: ws)
            let store = fixture.store

            try await store.deleteEntity(id: fixture.entityID)
            let deleted = try #require(try await store.entity(id: fixture.entityID))
            #expect(deleted.deleted)

            let totalBefore = try await store.entities(kind: nil, includeDeleted: true).count

            for pass in 1...3 {
                let aggressive = RewritingExtractor(
                    base: RuleExtractor(),
                    confidence: 0.8 + Double(pass) * 0.05,
                    detail: "Re-observed on pass \(pass)",
                    dueAt: TestClock.days(Double(50 + pass))
                )
                let service = MemoryService(store: store, extractors: [aggressive])
                _ = try await service.consolidate(
                    since: TestClock.hours(-1),
                    now: TestClock.days(Double(10 + pass))
                )

                let after = try #require(try await store.entity(id: fixture.entityID))
                #expect(after.deleted, "pass \(pass) resurrected a deleted entity")
                #expect(after.corrected, "pass \(pass) cleared the corrected flag on a deleted entity")
                #expect(after.title == fixture.correctedTitle, "pass \(pass) rewrote a deleted entity's title")

                let live = try await store.entities(kind: nil, includeDeleted: false)
                #expect(!live.contains { $0.id == fixture.entityID }, "pass \(pass) made it visible again")

                let total = try await store.entities(kind: nil, includeDeleted: true).count
                #expect(total == totalBefore, "pass \(pass) re-created it as a new row")
            }
        }
    }
}

// MARK: - CF-2 · Nothing leaves the machine when local-only

@Suite("CF-2 local-only means no outbound traffic")
struct CF2LocalOnlyTests {

    @Test("CF-2 capture, consolidate, ask and an MCP-shaped query make zero requests")
    func fullPipelineIsSilent() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()

            // The dangerous configuration on purpose: a key *is* present, the user simply has
            // not consented to cloud use. If the router leaks anywhere, it leaks here.
            let router = BrainRouter(
                preferred: .anthropicAPI,
                store: store,
                config: TestBrainConfig.keyedButLocalOnly
            )

            // ── 1. Capture ──────────────────────────────────────────────────────────────
            let front = FrontmostApp(bundleID: "com.tinyspeck.slackmacgap", name: "Slack", pid: 4_101)
            let source = TrustCaptureSpy(events: Fixtures.all(startingAt: TestClock.reference))
            let loop = CaptureLoop(
                source: source,
                store: store,
                config: CaptureConfig(),
                frontmostApp: { front },
                idleSeconds: { 0 }
            )
            for step in 0..<5 {
                await loop.tick(now: TestClock.minutes(Double(step * 6)))
            }
            await loop.stop(now: TestClock.minutes(30))
            let captured = try await store.captures(since: .distantPast, limit: 0)
            #expect(captured.count == 5, "the capture stage must have done real work")
            assertNoNetwork()

            // ── 2. Consolidate ──────────────────────────────────────────────────────────
            // The LLM pass asks the real router for a brain, so the routing decision, not a
            // hand-picked brain, is what keeps extraction local. The decision is asserted from
            // the dangerous preference; the pass then actually runs through the in-process
            // floor, for the reason at the top of this file.
            let extractionChain = await router.chain()
            #expect(
                !extractionChain.contains { $0.isCloud },
                "extraction could reach a cloud brain: \(extractionChain)"
            )
            await router.setPreferred(.rulesOnly)

            let service = MemoryService(
                store: store,
                // Guided generation off on purpose: this flow proves the extraction stage
                // honours the router's cloud veto, so it must actually reach the router. The
                // guided path is on-device by construction and would satisfy CF-2 trivially
                // while proving nothing about the path a machine without FoundationModels takes.
                extractors: [
                    RuleExtractor(),
                    LLMExtractor(brain: RouterBackedBrain(router: router), useGuidedGeneration: false),
                ]
            )
            let touched = try await service.consolidate(
                since: TestClock.hours(-1),
                now: TestClock.minutes(40)
            )
            #expect(touched > 0, "the consolidate stage must have done real work")
            assertNoNetwork()

            // Back to the configuration that would leak if anything could.
            await router.setPreferred(.anthropicAPI)

            // ── 3. Ask ──────────────────────────────────────────────────────────────────
            let packet = try await service.context(
                for: "what do I owe anyone",
                budget: 2_000,
                now: TestClock.minutes(45)
            )
            #expect(!packet.summary.isEmpty, "the ask stage must have real context to work with")

            // No cloud brain is even in the running, whatever the environment offers.
            let chain = await router.chain()
            #expect(!chain.contains { $0.isCloud }, "a cloud brain is reachable from the ask stage: \(chain)")

            let answer = try await localAnswer(
                from: router,
                question: "what do I owe anyone",
                context: packet
            )
            #expect(!answer.text.isEmpty)
            #expect(!answer.brain.isCloud, "a cloud brain answered while allowCloud was false")
            for id in answer.citedCaptureIDs {
                #expect(try await store.capture(id: id) != nil, "cited capture \(id) does not exist")
            }
            assertNoNetwork()

            // ── 4. MCP-shaped query ─────────────────────────────────────────────────────
            // The real server is a separate process, so a URLProtocol in this one could not
            // observe it. What is asserted here is that the reads the five tools perform,
            // against a read-only connection to the same file, touch nothing outbound.
            let readOnly = try await ws.readOnlyStore()
            #expect(readOnly.isReadOnly)
            let recalled = try await readOnly.searchEntities("rate limiter", limit: 8)
            #expect(!recalled.isEmpty, "the MCP-shaped stage must have something to return")
            _ = try await readOnly.searchCaptures("rate limiter", limit: 8)
            _ = try await readOnly.entities(kind: .commitment, includeDeleted: false)
            _ = try await readOnly.entities(kind: .person, includeDeleted: false)
            _ = try await readOnly.sessions(from: TestClock.days(-1), to: TestClock.days(1))
            let trace = try await readOnly.provenance(entityID: try #require(recalled.first).id)
            #expect(!trace.isEmpty)
            await readOnly.close()
            assertNoNetwork()

            #expect(
                BlockingURLProtocol.unexpectedRequests.isEmpty,
                "outbound requests were attempted: \(BlockingURLProtocol.unexpectedRequests)"
            )
        }
    }

    @Test("CF-2 the local-only router never constructs a brain that can reach the network")
    func routerBuildsNothingThatCanLeak() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            try await seed(store: store, captures: [Fixtures.email(at: TestClock.reference)])

            for preferred in BrainKind.allCases {
                let router = BrainRouter(
                    preferred: preferred,
                    store: store,
                    config: TestBrainConfig.keyedButLocalOnly
                )
                let chain = await router.chain()
                #expect(
                    !chain.contains { $0.isCloud },
                    "preferred \(preferred.rawValue) produced a chain containing a cloud brain: \(chain)"
                )
                // Safe to enumerate here only because allowCloud is false: with cloud on this
                // would probe `claudeCode` through the login shell. See `TestBrainConfig`.
                let available = await router.available()
                #expect(!available.contains { $0.isCloud }, "preferred \(preferred.rawValue): \(available)")
            }
            assertNoNetwork()
        }
    }
}

// MARK: - CF-2b · The outbound counter is measured, not inferred

/// PRIVACY.md offers the counter in Settings → Data as the thing that means you do not have to
/// take the rest on faith. It therefore has to be true at the point of sending.
///
/// It was not. `OutboundCounter` lived in `MemoirApp`, which `MemoirKit` cannot import, so the
/// brains had no way to reach it even in principle; the one increment sat in the ask handler
/// and fired from `reply.brain.isCloud` *after* an answer came back. It counted answers, not
/// requests: missing extraction's `complete()`, the `memoir-ask` CLI, the network brain, and
/// every request that failed. These tests exist so it cannot drift back.
/// A `Sendable` collector for what an observer was told, since the callback is `@Sendable`
/// and a captured local array is not.
private final class CountBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Int] = []
    func append(_ value: Int) {
        lock.lock(); defer { lock.unlock() }
        storage.append(value)
    }
    var values: [Int] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }
}

@Suite("CF-2b outbound requests are counted where they are sent")
struct CF2bOutboundCountingTests {

    /// Counting, and what it records.
    ///
    /// Deliberately exercised on a fresh instance rather than by making a real request: the
    /// suite's URL blocker records every attempt process-wide, so a test that genuinely sends
    /// would poison `assertNoNetwork()` for everything running beside it. The wiring is pinned
    /// by ``recordingHappensBeforeTheSend`` instead.
    @Test("CF-2b the monitor counts sends and remembers where the last one went")
    func monitorCounts() {
        let monitor = OutboundMonitor()
        #expect(monitor.snapshot.count == 0)
        #expect(monitor.snapshot.lastDestination == nil)

        monitor.record(destination: "api.anthropic.com")
        monitor.record(destination: "100.66.109.26")

        #expect(monitor.snapshot.count == 2)
        #expect(monitor.snapshot.lastDestination == "100.66.109.26")
    }

    @Test("CF-2b an observer sees the current value immediately and every later one")
    func monitorNotifies() {
        let monitor = OutboundMonitor()
        monitor.record(destination: "api.anthropic.com")

        let seen = CountBox()
        monitor.observe { snapshot in seen.append(snapshot.count) }
        monitor.record(destination: "Claude Code")

        #expect(seen.values == [1, 2], "an observer must be told the state it joined at")
    }

    /// The counter is a `MemoirKit` concern precisely so no caller has to remember it. If a
    /// send site appears outside these five, this is the test that should have caught it.
    ///
    /// It has now earned its keep twice: the update check went red here on the run that added
    /// it, and so did the weather lookup. That is the only reason the list below is a decision
    /// rather than a discovery someone makes later while reading a packet capture.
    ///
    /// Weather is the one to be suspicious of on re-reading. It is the only entry that says
    /// anything about *where* the user is and the only one that fires from opening a pane
    /// rather than from asking a question, allowed on the terms argued in `Scripts/verify.sh`
    /// and stated in PRIVACY.md: its own switch, off by default, an ~11 km coordinate, and
    /// nothing attached that identifies the machine.
    @Test("CF-2b nothing but the five send sites records")
    func onlyTheSendSitesRecord() throws {
        var callers: Set<String> = []
        for url in Self.swiftSources() {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            if text.contains("OutboundMonitor.shared.record") {
                callers.insert(url.lastPathComponent)
            }
        }
        #expect(
            callers == ["AnthropicBrain.swift", "LocalNetworkBrain.swift",
                        "ClaudeCodeBrain.swift", "UpdateCheck.swift", "Weather.swift"],
            "the set of send sites changed: \(callers.sorted())"
        )
    }

    /// **The invariant the old design got wrong.** Counting after a call returns means a
    /// request that fails is never counted, and a failed request still left the machine. So
    /// the `record` must lexically precede the send in every brain.
    @Test("CF-2b every brain records before it sends, not after")
    func recordingHappensBeforeTheSend() throws {
        // Each needle is the line that actually carries the user's context out. For Claude
        // Code that is the answering spawn specifically, not the earlier `command -v claude`
        // probe: resolving a path sends nothing and is deliberately not counted.
        let sends: [String: String] = [
            "AnthropicBrain.swift": "Self.session.data(for: request)",
            "LocalNetworkBrain.swift": "Self.session.data(for: request)",
            "ClaudeCodeBrain.swift": #"arguments: ["-p", payload]"#,
        ]
        for url in Self.swiftSources() where sends.keys.contains(url.lastPathComponent) {
            let text = try String(contentsOf: url, encoding: .utf8)
            let lines = text.components(separatedBy: .newlines)
            guard let recordAt = lines.firstIndex(where: { $0.contains("OutboundMonitor.shared.record") }) else {
                Issue.record("\(url.lastPathComponent) does not count its request at all")
                continue
            }
            guard let needle = sends[url.lastPathComponent],
                  let sendAt = lines.firstIndex(where: { $0.contains(needle) }) else {
                Issue.record("\(url.lastPathComponent): could not find the send site")
                continue
            }
            let detail = "\(url.lastPathComponent) counts at line \(recordAt + 1) but sends at "
                + "line \(sendAt + 1): a request that fails would go uncounted"
            #expect(recordAt < sendAt, "\(detail)")
        }
    }

    /// **The update check existed, was tested, was documented, and nothing called it.**
    ///
    /// `UpdateCheck` shipped with unit tests and a paragraph in PRIVACY.md calling it "the one
    /// thing that goes out without you asking", while no line in the app ever invoked it. Every
    /// test passed and the promise was false: an installed copy could never learn that a bug had
    /// been fixed. This is the same failure as the extraction pass that was wired to nothing.
    ///
    /// A unit test cannot catch that, because the unit worked. So this reads the app's own
    /// source and asserts the call exists, and that the switch is consulted in the same file:
    /// a check that fired regardless of `allowUpdateCheck` would make the setting a lie.
    @Test("the app actually asks whether a newer version exists")
    func updateCheckIsWiredIntoTheApp() throws {
        // Comments are stripped before looking. The first version of this test searched the
        // whole file, and the doc comment above the call site names `UpdateCheck.latest`, so
        // deleting the actual call left the test green. Verified by deleting it again.
        func code(_ url: URL) -> String? {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            return text
                .split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
        }

        let callers = Self.swiftSources().filter { url in
            guard url.path.contains("/MemoirApp/"), let body = code(url) else { return false }
            return body.contains("UpdateCheck.latest(")
        }
        #expect(!callers.isEmpty, "nothing in MemoirApp calls UpdateCheck.latest")

        for url in callers {
            #expect(
                code(url)?.contains("allowUpdateCheck") == true,
                "\(url.lastPathComponent) checks for updates without consulting the switch"
            )
        }
    }

    private static func swiftSources() -> [URL] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Integration
            .deletingLastPathComponent()   // MemoirKitTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("Sources")
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
            return []
        }
        return walker.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }

    /// The whole local-only pipeline, asserted against the counter rather than only against
    /// the URL blocker: the two agree, which is what makes the number in Settings meaningful.
    @Test("CF-2b a local-only answer increments nothing")
    func localOnlyAnswerCountsZero() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            try await seed(store: store, captures: Fixtures.all(startingAt: TestClock.reference))

            let before = OutboundMonitor.shared.snapshot.count
            let router = BrainRouter(
                preferred: .anthropicAPI,
                store: store,
                config: TestBrainConfig.keyedButLocalOnly
            )
            let packet = ContextPacket.empty
            _ = try? await router.answer(question: "what did I say I would do?", context: packet)

            #expect(
                OutboundMonitor.shared.snapshot.count == before,
                "a local-only answer sent something"
            )
            assertNoNetwork()
        }
    }
}

// MARK: - CF-3 · A cloud brain is never selected without consent

@Suite("CF-3 no cloud brain without consent")
struct CF3NoCloudWithoutConsentTests {

    @Test("CF-3 preferring anthropicAPI with allowCloud off resolves to a local brain")
    func explicitCloudPreferenceResolvesLocal() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            try await seed(store: store, captures: Fixtures.all(startingAt: TestClock.reference))

            let router = BrainRouter(
                preferred: .anthropicAPI,
                store: store,
                config: TestBrainConfig.keyedButLocalOnly
            )

            #expect(await router.preferredKind() == .anthropicAPI, "the user's choice is still recorded")
            // What may run is "everything that stays on this Mac", which is a smaller set than
            // "everything that is not cloud". `localNetwork` is not cloud (no third party, no
            // account), but it POSTs the context packet to another host, so it sits behind
            // `allowLocalNetwork` and is blocked here alongside the cloud brains. This
            // assertion used to read `allowed == !kind.isCloud` and passed while the network
            // brain ran on nothing but an endpoint being configured.
            let staysOnThisMac: Set<BrainKind> = [.appleOnDevice, .rulesOnly]
            for kind in BrainKind.allCases {
                let allowed = await router.isAllowed(kind)
                #expect(
                    allowed == staysOnThisMac.contains(kind),
                    "\(kind.rawValue) allowed: \(allowed)"
                )
            }

            let chain = await router.chain()
            #expect(!chain.contains(.anthropicAPI), "the cloud brain is still in the fallback chain: \(chain)")
            #expect(!chain.contains(.claudeCode))
            #expect(chain.last == .rulesOnly, "the chain must always end at the local floor")

            let current = await router.current()
            #expect(!current.isCloud, "the router selected \(current.rawValue)")

            // The settings screen says so out loud rather than pretending the brain is broken,
            // and building it is refused, so nothing with a key in it is ever constructed.
            for cloud in BrainKind.allCases where cloud.isCloud {
                let detail = await router.availabilityDetail(for: cloud)
                #expect(detail.contains("switched off"), "\(cloud.rawValue): \(detail)")
            }

            let packet = ContextPacket(summary: "Open commitments:\n- send the agenda", captureIDs: [], entityIDs: [])
            let answer = try await localAnswer(from: router, question: "what do I owe anyone", context: packet)
            #expect(!answer.brain.isCloud, "\(answer.brain.rawValue) answered")
            #expect(!answer.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            // The key is configured and still nothing reached out.
            #expect(await router.redactedConfig().anthropicAPIKey == nil)
            assertNoNetwork()
        }
    }

    @Test("CF-3 switching the preference to a cloud brain at runtime still resolves local")
    func settingCloudPreferredLaterStillResolvesLocal() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            let router = BrainRouter(preferred: .rulesOnly, store: store, config: TestBrainConfig.localOnly)

            for cloud in BrainKind.allCases where cloud.isCloud {
                await router.setPreferred(cloud)
                #expect(await router.preferredKind() == cloud)

                let chain = await router.chain()
                #expect(!chain.contains { $0.isCloud }, "\(cloud.rawValue): \(chain)")

                let current = await router.current()
                #expect(!current.isCloud, "\(cloud.rawValue) resolved to \(current.rawValue)")
            }

            // And a config swap that keeps cloud off must not open the door either.
            await router.setConfig(TestBrainConfig.keyedButLocalOnly)
            let after = await router.current()
            #expect(!after.isCloud, "a config update selected \(after.rawValue)")
            assertNoNetwork()
        }
    }

    @Test("CF-3 with the store broken under it, the fallback is still local and still answers")
    func fallbackIsLocalEvenWhenLocalBrainsAreDegraded() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            let router = BrainRouter(
                preferred: .anthropicAPI,
                store: store,
                config: TestBrainConfig.keyedButLocalOnly
            )

            // `RulesOnlyBrain` is always "available" by design: it is CF-18's floor and there
            // is no supported way to switch it off. The closest thing to "every local brain is
            // unavailable" the real router allows is a store that fails every read underneath
            // it, which is what this does.
            await store.close()

            let chain = await router.chain()
            #expect(!chain.contains { $0.isCloud }, "\(chain)")

            let answer = try await localAnswer(from: router, question: "what do I owe anyone", context: .empty)
            #expect(!answer.brain.isCloud, "\(answer.brain.rawValue) answered a degraded request")
            #expect(!answer.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            assertNoNetwork()
        }
    }

    @Test("CF-3 a failing local brain never causes a fall back to the cloud")
    func failingPreferredBrainDoesNotFallBackToCloud() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            try await seed(store: store, captures: [Fixtures.standupNotes(at: TestClock.reference)])

            // A brain that reports itself available and then throws is the shape a naive router
            // gets wrong, so the chain is asked for twice: `answer` marks a failed brain
            // unavailable in its cache, and the second pass must still not reach for the cloud.
            let router = BrainRouter(
                preferred: .anthropicAPI,
                store: store,
                config: TestBrainConfig.keyedButLocalOnly
            )
            for attempt in 1...2 {
                let chain = await router.chain()
                #expect(!chain.contains { $0.isCloud }, "attempt \(attempt): \(chain)")
                let answer = try await localAnswer(
                    from: router,
                    question: "what did I say I would do",
                    context: .empty
                )
                #expect(!answer.brain.isCloud, "attempt \(attempt) answered with \(answer.brain.rawValue)")
                // Put the dangerous preference back so the next attempt starts from it again.
                await router.setPreferred(.anthropicAPI)
            }
            assertNoNetwork()
        }
    }
}

// MARK: - CF-4 · The API key never persists outside the Keychain

@Suite("CF-4 the API key stays in the Keychain")
struct CF4KeyNeverPersistsTests {

    @Test("CF-4 after a full pipeline the key is in none of the database, config, log or defaults")
    func keyNeverReachesDisk() async throws {
        // A throwaway Keychain item, so the user's own `sh.memoir.brain` / `anthropic` entry is
        // never read, never replaced and never deleted by this test.
        let item = BrainKeychain.Item(
            service: "sh.memoir.tests.trust.\(ProcessInfo.processInfo.processIdentifier)",
            account: "anthropic"
        )

        try await BrainKeychain.$itemOverride.withValue(item) {
            try await TestWorkspace.with { ws in
                // 1. Save the key the way the app does.
                var keychainAccepted = true
                do {
                    try BrainKeychain.save(apiKey: TestSecrets.apiKey)
                } catch {
                    // A locked or absent login keychain (some CI images) must not turn this
                    // flow into a false pass: the grep below still runs, with the key held in
                    // memory exactly as `BrainRouter` would hold it.
                    keychainAccepted = false
                    Log.shared.warn("CF-4 could not use the Keychain: \(error)")
                }
                defer { try? BrainKeychain.delete() }

                if keychainAccepted {
                    #expect(BrainKeychain.load() == TestSecrets.apiKey, "the key is not in the Keychain")
                    #expect(BrainKeychain.hasKey())
                    #expect(
                        BrainConfig().withKeychainKey().anthropicAPIKey == TestSecrets.apiKey,
                        "withKeychainKey is the only supported way to load the key"
                    )
                }

                // 2. Write config.json exactly the way the app does.
                try ws.writeConfig(
                    BrainConfig(
                        anthropicAPIKey: TestSecrets.apiKey,
                        anthropicModel: "claude-sonnet-5",
                        claudeCodePath: nil,
                        allowCloud: false
                    )
                )

                // 3. Run the whole pipeline with the key live in memory.
                let store = try await ws.store()
                try await seed(
                    store: store,
                    captures: Fixtures.all(startingAt: TestClock.reference),
                    sessions: [
                        makeSession(
                            appName: "Slack",
                            bundleID: "com.tinyspeck.slackmacgap",
                            from: TestClock.reference,
                            to: TestClock.minutes(30)
                        )
                    ]
                )
                let service = MemoryService(store: store, extractors: [RuleExtractor()])
                _ = try await service.consolidate(since: TestClock.hours(-1), now: TestClock.minutes(35))

                let router = BrainRouter(
                    preferred: .anthropicAPI,
                    store: store,
                    config: TestBrainConfig.keyedButLocalOnly
                )
                await router.setConfig(TestBrainConfig.keyedButLocalOnly)
                let packet = try await service.context(
                    for: "what do I owe anyone",
                    budget: 1_500,
                    now: TestClock.minutes(40)
                )
                let answer = try await localAnswer(
                    from: router,
                    question: "what do I owe anyone",
                    context: packet
                )
                #expect(!answer.text.isEmpty)
                #expect(!answer.brain.isCloud)
                _ = try await service.applyRetention(captureDays: 60, now: TestClock.minutes(45))
                _ = try await store.stats()
                await store.close()

                // 4. Grep everything that touched the disk.
                let databaseBytes = ws.databaseBytes()
                let config = ws.configContents()
                let log = ws.logContents()
                let defaults = userDefaultsBytes()

                // Positive controls first: if these fail, the greps below are vacuous.
                #expect(!databaseBytes.isEmpty, "no database bytes to search")
                #expect(
                    databaseBytes.range(of: Data("rate limiter".utf8)) != nil,
                    "the database search would not find the key even if it were there"
                )
                #expect(config.contains("allowCloud"), "config.json was not written")
                #expect(!log.isEmpty, "the log file was not written")
                #expect(!defaults.isEmpty, "the UserDefaults snapshot is empty")

                for needle in [TestSecrets.apiKey, TestSecrets.apiKeyNeedle, "sk-ant-api03"] {
                    let bytes = Data(needle.utf8)
                    #expect(databaseBytes.range(of: bytes) == nil, "\"\(needle)\" leaked into the database")
                    #expect(!config.contains(needle), "\"\(needle)\" leaked into config.json")
                    #expect(!log.contains(needle), "\"\(needle)\" leaked into the log file")
                    #expect(defaults.range(of: bytes) == nil, "\"\(needle)\" leaked into UserDefaults")
                }
                #expect(!ws.anyArtifactContains(TestSecrets.apiKeyNeedle))

                // 5. The two shapes the key could escape through in a UI or a log line.
                let redactedConfig = await router.redactedConfig()
                #expect(redactedConfig.anthropicAPIKey == nil)
                #expect(!redactedConfig.redactedDescription.contains(TestSecrets.apiKeyNeedle))
                #expect(
                    !BrainKeychain.redact("authorization: \(TestSecrets.apiKey) trailing")
                        .contains(TestSecrets.apiKeyNeedle)
                )
                assertNoNetwork()
            }
        }
    }

    @Test("CF-4 the config encoder drops the key even when it is set")
    func configEncoderDropsTheKey() async throws {
        try await TestWorkspace.with { ws in
            let config = BrainConfig(
                anthropicAPIKey: TestSecrets.apiKey,
                claudeCodePath: "/opt/homebrew/bin/claude",
                allowCloud: false
            )
            try ws.writeConfig(config)

            let text = ws.configContents()
            #expect(text.contains("claude"), "the rest of the config must still round-trip")
            #expect(!text.contains(TestSecrets.apiKeyNeedle))
            #expect(!text.lowercased().contains("apikey"), "even the key's field name should be absent")

            let decoded = try JSONDecoder().decode(BrainConfig.self, from: Data(ws.configContents().utf8))
            #expect(decoded.anthropicAPIKey == nil, "decoding must never restore a key from the file")
            #expect(decoded.allowCloud == false)
        }
    }
}

// MARK: - CF-5 · Excluded apps are never captured

@Suite("CF-5 excluded apps produce no rows at all")
struct CF5ExcludedAppsTests {

    private func event(for app: FrontmostApp, at ts: Date, text: String, name: String) -> CaptureEvent {
        Fixtures.capture(
            text: text,
            app: app.name,
            bundleID: app.bundleID,
            windowTitle: "\(app.name) window",
            at: ts,
            name: name
        )
    }

    @Test("CF-5 an excluded app leaves no capture row, no session row and is never even read")
    func excludedAppLeavesNothingBehind() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            let excluded = FrontmostApp(bundleID: "com.1password.1password", name: "1Password", pid: 7_701)
            #expect(CaptureConfig().isExcluded(excluded.bundleID), "the fixture app must be excluded by default")

            let secret = "MASTER-PASSWORD-MEMOIRTRUST-0001"
            let source = TrustCaptureSpy(events: [
                event(for: excluded, at: TestClock.reference, text: "Vault: \(secret)", name: "cf5-excluded-1"),
                event(for: excluded, at: TestClock.seconds(6), text: "Vault: \(secret) again", name: "cf5-excluded-2"),
            ])
            let loop = CaptureLoop(
                source: source,
                store: store,
                config: CaptureConfig(),
                frontmostApp: { excluded },
                idleSeconds: { 0 }
            )

            await loop.tick(now: TestClock.reference)
            await loop.tick(now: TestClock.seconds(6))
            await loop.stop(now: TestClock.seconds(12))

            let captures = try await store.captures(since: .distantPast, limit: 0)
            #expect(captures.isEmpty, "an excluded app produced \(captures.count) capture rows")

            let sessions = try await store.sessions(from: .distantPast, to: .distantFuture)
            #expect(sessions.isEmpty, "an excluded app produced \(sessions.count) session rows")

            #expect(source.calls == 0, "the source was read \(source.calls) times for an excluded app")
            #expect(await loop.capturesWritten == 0)

            // Absent, not truncated and not redacted: neither the text nor the app's identity
            // is anywhere in the file.
            await store.close()
            let bytes = ws.databaseBytes()
            #expect(bytes.range(of: Data(secret.utf8)) == nil, "the excluded app's text is on disk")
            #expect(bytes.range(of: Data(excluded.bundleID.utf8)) == nil, "the excluded app's identity is on disk")
        }
    }

    @Test("CF-5 an allowed app in the same setup does land, so the negative result means something")
    func allowedAppIsTheControl() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            let allowed = FrontmostApp(bundleID: "com.apple.TextEdit", name: "TextEdit", pid: 7_702)
            #expect(!CaptureConfig().isExcluded(allowed.bundleID))

            let source = TrustCaptureSpy(events: [
                event(for: allowed, at: TestClock.reference, text: "Draft the Q2 agenda.", name: "cf5-allowed-1"),
                event(for: allowed, at: TestClock.seconds(6), text: "Draft the Q2 agenda, revised.", name: "cf5-allowed-2"),
            ])
            let loop = CaptureLoop(
                source: source,
                store: store,
                config: CaptureConfig(),
                frontmostApp: { allowed },
                idleSeconds: { 0 }
            )

            await loop.tick(now: TestClock.reference)
            await loop.tick(now: TestClock.seconds(6))
            await loop.stop(now: TestClock.seconds(12))

            let captures = try await store.captures(since: .distantPast, limit: 0)
            #expect(captures.count == 2)
            #expect(captures.allSatisfy { $0.appBundleID == allowed.bundleID })
            #expect(source.calls == 2)
            #expect(await loop.capturesWritten == 2)

            let sessions = try await store.sessions(from: .distantPast, to: .distantFuture)
            #expect(sessions.count == 1)
            #expect(sessions.first?.appBundleID == allowed.bundleID)
        }
    }

    @Test("CF-5 switching from an allowed app into an excluded one closes the session and records nothing")
    func switchingIntoAnExcludedAppRecordsNothing() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            let allowed = FrontmostApp(bundleID: "com.apple.TextEdit", name: "TextEdit", pid: 7_703)
            let excluded = FrontmostApp(bundleID: "com.apple.keychainaccess", name: "Keychain Access", pid: 7_704)
            #expect(CaptureConfig().isExcluded(excluded.bundleID))

            let script = TrustFrontmostScript(allowed)
            let secret = "KEYCHAIN-ITEM-MEMOIRTRUST-0002"
            let source = TrustCaptureSpy(events: [
                event(for: allowed, at: TestClock.reference, text: "Notes for the review.", name: "cf5-switch-1"),
                event(for: excluded, at: TestClock.seconds(6), text: "Password: \(secret)", name: "cf5-switch-2"),
                event(for: excluded, at: TestClock.seconds(12), text: "Password: \(secret) shown", name: "cf5-switch-3"),
            ])
            let loop = CaptureLoop(
                source: source,
                store: store,
                config: CaptureConfig(),
                frontmostApp: { script.current },
                idleSeconds: { 0 }
            )

            await loop.tick(now: TestClock.reference)
            script.set(excluded)
            await loop.tick(now: TestClock.seconds(6))
            await loop.tick(now: TestClock.seconds(12))
            await loop.stop(now: TestClock.seconds(18))

            let captures = try await store.captures(since: .distantPast, limit: 0)
            #expect(captures.count == 1, "expected only the allowed app's capture")
            #expect(captures.first?.appBundleID == allowed.bundleID)

            let sessions = try await store.sessions(from: .distantPast, to: .distantFuture)
            #expect(sessions.count == 1, "a session was opened for an excluded app")
            #expect(sessions.allSatisfy { $0.appBundleID != excluded.bundleID })
            #expect(sessions.first?.appBundleID == allowed.bundleID)
            // The loop cannot know when between two polls the switch happened, so it closes the
            // outgoing session at the tick that noticed, exactly as it does for an ordinary app
            // switch. What matters here is that it cannot run *past* that moment.
            #expect(
                (sessions.first?.endedAt ?? .distantFuture) <= TestClock.seconds(6),
                "the allowed app's session ran on past the point the excluded app took over"
            )

            #expect(source.calls == 1, "the excluded app was read \(source.calls - 1) times")

            await store.close()
            let bytes = ws.databaseBytes()
            #expect(bytes.range(of: Data(secret.utf8)) == nil)
            #expect(bytes.range(of: Data(excluded.bundleID.utf8)) == nil)
        }
    }

    @Test("CF-5 an exclusion the user added themselves is honoured the same way")
    func userAddedExclusionIsHonoured() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            let app = FrontmostApp(bundleID: "com.example.private-journal", name: "Journal", pid: 7_705)
            #expect(!CaptureConfig().isExcluded(app.bundleID), "must not already be excluded by default")

            var config = CaptureConfig()
            config.excludedBundleIDs.insert(app.bundleID)

            let source = TrustCaptureSpy(events: [
                event(for: app, at: TestClock.reference, text: "Private entry, MEMOIRTRUST-0003.", name: "cf5-user-1")
            ])
            let loop = CaptureLoop(
                source: source,
                store: store,
                config: config,
                frontmostApp: { app },
                idleSeconds: { 0 }
            )
            await loop.tick(now: TestClock.reference)

            let captures = try await store.captures(since: .distantPast, limit: 0)
            #expect(captures.isEmpty)
            #expect(try await store.sessions(from: .distantPast, to: .distantFuture).isEmpty)
            #expect(source.calls == 0)
        }
    }

    @Test("CF-5 every bundle identifier on the shipped exclusion list is actually excluded")
    func everyDefaultExclusionIsEnforced() {
        let config = CaptureConfig()
        #expect(!CaptureConfig.defaultExcludedBundleIDs.isEmpty)
        for bundleID in CaptureConfig.defaultExcludedBundleIDs {
            #expect(config.isExcluded(bundleID), "\(bundleID) is on the list but not excluded")
        }
        // The list is exact-match, so a lookalike must not be silently excluded either.
        #expect(!config.isExcluded("com.1password.1password.helper"))
        #expect(!config.isExcluded("com.apple.Safari"))
    }
}

// MARK: - CF-6 · Secure fields are never read

/// The accessibility tree cannot be walked in a test process: it needs a granted
/// Accessibility permission and a live window server, and `FrontmostApp.current()` would
/// return the test runner. The traversal itself is therefore exercised where it lives, in
/// `BoundedTextWalk` (the same function `AXScraper` drives, with the same limits) over a
/// synthetic tree whose nodes record every read made of them.
///
/// That makes two things assertable that a real AX walk could not prove: that no attribute of
/// a secure field is read *at all*, and that its subtree is never requested.
@Suite("CF-6 secure fields are never read")
struct CF6SecureFieldTests {

    private static let secret = "hunter2-MEMOIRSECRET-DO-NOT-CAPTURE"

    /// A sign-in window with one password field that has a child carrying the same secret.
    private func signInWindow() -> (root: TrustAXNode, secure: TrustAXNode, hidden: TrustAXNode) {
        let hidden = TrustAXNode(name: "secure-child", texts: ["\(Self.secret)-inner"])
        let secure = TrustAXNode(
            name: "password-field",
            texts: ["Password", Self.secret],
            children: [hidden],
            isSecure: true
        )
        let root = TrustAXNode(
            name: "window",
            texts: ["Acme Bank, Sign in"],
            children: [
                TrustAXNode(name: "email-label", texts: ["Email"]),
                TrustAXNode(name: "email-field", texts: ["elena@acme.example"]),
                secure,
                TrustAXNode(name: "submit", texts: ["Sign in"]),
            ]
        )
        return (root, secure, hidden)
    }

    private func walk(_ roots: [TrustAXNode], maxCharacters: Int = CaptureLimits.maxCharacters) -> BoundedTextWalk.Outcome {
        BoundedTextWalk.run(
            roots: roots,
            limits: TextWalkLimits.standard(maxCharacters: maxCharacters, isOutOfTime: { false }),
            isSecure: { $0.isSecure },
            texts: { $0.readTexts() },
            children: { $0.readChildren() }
        )
    }

    @Test("CF-6 a secure field contributes no text and the walk does not descend into it")
    func secureFieldIsSkippedWhole() throws {
        let tree = signInWindow()
        let outcome = walk([tree.root])
        let text = outcome.text

        // Everything around it is still collected.
        #expect(text.contains("Acme Bank"))
        #expect(text.contains("Email"))
        #expect(text.contains("elena@acme.example"))
        #expect(text.contains("Sign in"))

        // The field itself contributes nothing: not its value, not its label.
        #expect(!text.contains("MEMOIRSECRET"), "a secure field's value was collected: \(text)")
        #expect(!text.contains("Password"), "a secure field's label was collected: \(text)")

        // Nothing about it was even read.
        #expect(tree.secure.textReads == 0, "the walk read the attributes of \(tree.secure.name)")
        #expect(tree.secure.childReads == 0, "the walk asked \(tree.secure.name) for its children")
        #expect(tree.hidden.textReads == 0, "the walk read \(tree.hidden.name), inside a secure subtree")
        #expect(tree.hidden.childReads == 0)

        // The node is visited and counted, it just yields nothing and goes no deeper.
        #expect(outcome.nodesVisited == 5)
        #expect(outcome.deepestVisited == 1, "the walk descended below the secure field's siblings")
        #expect(!outcome.hitLimit)
    }

    @Test("CF-6 a secure field nested deep in the tree is skipped just the same")
    func secureFieldDeepInTheTreeIsSkipped() throws {
        let buried = TrustAXNode(name: "buried-child", texts: ["\(Self.secret)-buried"])
        let secure = TrustAXNode(
            name: "buried-password",
            texts: [Self.secret],
            children: [buried],
            isSecure: true
        )
        let root = TrustAXNode(
            name: "root",
            texts: ["Settings"],
            children: [
                TrustAXNode(
                    name: "group",
                    texts: ["Accounts"],
                    children: [
                        TrustAXNode(name: "row", texts: ["Mail account"], children: [secure])
                    ]
                )
            ]
        )

        let outcome = walk([root])
        #expect(outcome.text.contains("Accounts"))
        #expect(outcome.text.contains("Mail account"))
        #expect(!outcome.text.contains("MEMOIRSECRET"))
        #expect(secure.textReads == 0)
        #expect(secure.childReads == 0)
        #expect(buried.textReads == 0)
    }

    @Test("CF-6 a secure field handed in as a root is skipped, not treated as an exception")
    func secureFieldAsARootIsSkipped() throws {
        let child = TrustAXNode(name: "root-secure-child", texts: ["\(Self.secret)-root-child"])
        let secure = TrustAXNode(name: "root-secure", texts: [Self.secret], children: [child], isSecure: true)
        let sibling = TrustAXNode(name: "other-root", texts: ["Visible root text"])

        let outcome = walk([secure, sibling])
        #expect(outcome.text == "Visible root text")
        #expect(!outcome.text.contains("MEMOIRSECRET"))
        #expect(secure.textReads == 0)
        #expect(secure.childReads == 0)
        #expect(child.textReads == 0)
    }

    @Test("CF-6 a password typed into a secure field never reaches the database")
    func secureFieldValueNeverReachesTheStore() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            let tree = signInWindow()
            let collected = walk([tree.root]).text
            #expect(!collected.isEmpty)

            // The capture is built from exactly what the real walk produced, then pushed
            // through the real loop into the real store and consolidated.
            let front = FrontmostApp(bundleID: "com.acme.bank", name: "Acme Bank", pid: 7_801)
            let event = CaptureEvent(
                id: TestID.stable("cf6", "signin"),
                ts: TestClock.reference,
                appBundleID: front.bundleID,
                appName: front.name,
                windowTitle: "Sign in",
                text: collected,
                textHash: AccessibilityCapture.textHash(collected)
            )
            let loop = CaptureLoop(
                source: TrustCaptureSpy(events: [event]),
                store: store,
                config: CaptureConfig(),
                frontmostApp: { front },
                idleSeconds: { 0 }
            )
            await loop.tick(now: TestClock.reference)
            await loop.stop(now: TestClock.seconds(6))

            let service = MemoryService(store: store, extractors: [RuleExtractor()])
            _ = try await service.consolidate(since: TestClock.hours(-1), now: TestClock.minutes(5))

            let stored = try await store.captures(since: .distantPast, limit: 0)
            #expect(stored.count == 1)
            #expect(stored.first?.text.contains("elena@acme.example") == true, "the visible text must have landed")
            #expect(stored.first?.text.contains("MEMOIRSECRET") == false)

            await store.close()
            let bytes = ws.databaseBytes()
            #expect(
                bytes.range(of: Data("elena@acme.example".utf8)) != nil,
                "the byte search would not find the password even if it were there"
            )
            #expect(bytes.range(of: Data("MEMOIRSECRET".utf8)) == nil, "a password reached the database file")
            #expect(!ws.anyArtifactContains("MEMOIRSECRET"))
        }
    }
}

// MARK: - CF-7 · Delete everything actually deletes everything

@Suite("CF-7 purge really purges")
struct CF7PurgeEverythingTests {

    @Test("CF-7 purgeEverything empties every table and both FTS indexes, and shrinks the file")
    func purgeEmptiesEverything() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()

            // Enough real data that a failure to vacuum is unmistakable on disk.
            let captures = fatCaptures(count: 160)
            let entities = makeEntities(count: 80, from: TestClock.reference, pinnedEvery: 7)
            let provenance = zip(entities, captures).map { entity, capture in
                makeProvenance(
                    entityID: entity.id,
                    captureID: capture.id,
                    snippet: "seeded provenance for \(entity.title)",
                    at: TestClock.reference
                )
            }
            let sessions = (0..<12).map { i in
                makeSession(
                    appName: "App \(i)",
                    bundleID: "sh.memoir.tests.app\(i)",
                    from: TestClock.hours(Double(i)),
                    to: TestClock.hours(Double(i) + 0.5)
                )
            }
            try await seed(
                store: store,
                captures: captures,
                entities: entities,
                provenance: provenance,
                sessions: sessions
            )

            // Everything is really there, and the indexes really work.
            let before = try await store.stats()
            #expect(before.captureCount == captures.count)
            #expect(before.entityCount == entities.count)
            #expect(before.sessionCount == sessions.count)
            #expect(before.oldestCapture != nil)
            #expect(!(try await store.searchCaptures("purgeable", limit: 20)).isEmpty, "capture search must work first")
            #expect(!(try await store.searchEntities("fixture", limit: 20)).isEmpty, "entity search must work first")
            #expect(!(try await store.provenance(entityID: entities[0].id)).isEmpty)

            let ftsBefore = try ftsCounts(at: ws.dbURL)
            if let ftsBefore {
                #expect(ftsBefore.captures > 0, "captures_fts was never populated")
                #expect(ftsBefore.entities > 0, "entities_fts was never populated")
            }

            // ── Purge ───────────────────────────────────────────────────────────────────
            try await store.purgeEverything()

            let after = try await store.stats()
            #expect(after.captureCount == 0)
            #expect(after.entityCount == 0)
            #expect(after.sessionCount == 0)
            #expect(after.oldestCapture == nil)

            #expect((try await store.entities(kind: nil, includeDeleted: true)).isEmpty, "soft-deleted rows survived")
            #expect((try await store.captures(since: .distantPast, limit: 0)).isEmpty)
            #expect((try await store.sessions(from: .distantPast, to: .distantFuture)).isEmpty)
            for entity in entities.prefix(5) {
                #expect((try await store.provenance(entityID: entity.id)).isEmpty)
            }
            #expect((try await store.searchCaptures("purgeable", limit: 20)).isEmpty)
            #expect((try await store.searchEntities("fixture", limit: 20)).isEmpty)

            #expect(
                after.fileSizeBytes < before.fileSizeBytes / 2,
                "the file was not vacuumed: \(before.fileSizeBytes) bytes before, \(after.fileSizeBytes) after"
            )

            // ── The indexes themselves, read straight out of the file ───────────────────
            await store.close()
            let ftsAfter = try ftsCounts(at: ws.dbURL)
            if let ftsAfter {
                #expect(ftsAfter.captures == 0, "captures_fts still holds \(ftsAfter.captures) rows")
                #expect(ftsAfter.entities == 0, "entities_fts still holds \(ftsAfter.entities) rows")
            } else {
                // A SQLite build without FTS5 is a supported degradation; the LIKE-based
                // searches above already proved the data is gone.
                Log.shared.warn("CF-7 ran without FTS5, so only the LIKE fallback was asserted")
            }

            // Nothing recognisable is left in the bytes on disk.
            let bytes = ws.databaseBytes()
            #expect(bytes.range(of: Data("purgeable".utf8)) == nil, "capture text survived the purge")
            #expect(bytes.range(of: Data("seeded provenance".utf8)) == nil, "provenance snippets survived the purge")
        }
    }

    @Test("CF-7 a purged store is usable again and a second purge is harmless")
    func purgeIsRepeatableAndTheStoreStillWorks() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            try await seed(store: store, captures: Fixtures.all(startingAt: TestClock.reference))

            try await store.purgeEverything()
            try await store.purgeEverything()
            #expect(try await store.stats().captureCount == 0)

            // The schema and the FTS triggers survived, so new data indexes correctly.
            try await seed(store: store, captures: [Fixtures.email(at: TestClock.days(1))])
            let found = try await store.searchCaptures("headcount", limit: 10)
            #expect(found.count == 1, "the store was unusable after a purge")
            #expect(try await store.stats().captureCount == 1)
        }
    }

    @Test("CF-7 a read-only store refuses to purge")
    func readOnlyStoreCannotPurge() async throws {
        try await TestWorkspace.with { ws in
            let writable = try await ws.store()
            try await seed(store: writable, captures: [Fixtures.slackThread(at: TestClock.reference)])
            await writable.close()

            let readOnly = try await ws.readOnlyStore()
            await #expect(throws: MemoirError.self) {
                try await readOnly.purgeEverything()
            }
            #expect(try await readOnly.stats().captureCount == 1, "the purge attempt must have changed nothing")
            await readOnly.close()
        }
    }

    /// A wipe that vacuums the live file to nothing while leaving whole copies of it in the
    /// same folder is a wipe the user can disprove with `ls`. CF-7b *requires* those copies to
    /// be written before a migration; nothing required them to survive this button.
    @Test("CF-7 the pre-migration snapshots do not survive delete everything")
    func purgeTakesTheMigrationBackups() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            try await seed(store: store, captures: Fixtures.all(startingAt: TestClock.reference))

            // Stand in for what `backUpBeforeMigrating` leaves behind, in its exact shape.
            let databaseURL = store.databaseURL
            let backups = [3, 4, 5].map {
                databaseURL.deletingLastPathComponent()
                    .appendingPathComponent("\(databaseURL.lastPathComponent).v\($0).backup")
            }
            for url in backups {
                try Data("not really a database, but the right name".utf8).write(to: url)
            }
            #expect(await store.migrationBackupURLs().count == 3, "the fixture did not take")

            try await store.purgeEverything()

            for url in backups {
                #expect(
                    !FileManager.default.fileExists(atPath: url.path),
                    "\(url.lastPathComponent) survived a delete-everything"
                )
            }
            #expect(await store.migrationBackupURLs().isEmpty)
        }
    }

    /// One spare copy is insurance against a bad upgrade. Four is a second database the user
    /// does not know they have, measured at 66 MB beside a 42 MB live file.
    @Test("CF-7 reaping keeps the newest snapshot and drops the rest, by version not by name")
    func reapingKeepsTheNewest() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            let databaseURL = store.databaseURL
            // 9 and 10 are the pair that a lexical sort gets wrong.
            let versions = [2, 9, 10]
            for version in versions {
                let url = databaseURL.deletingLastPathComponent()
                    .appendingPathComponent("\(databaseURL.lastPathComponent).v\(version).backup")
                try Data("x".utf8).write(to: url)
            }

            _ = await store.reapMigrationBackups(keepMostRecent: 1)

            let left = await store.migrationBackupURLs().map(\.lastPathComponent)
            #expect(left.count == 1, "expected one survivor, got \(left)")
            #expect(left.first?.hasSuffix(".v10.backup") == true, "kept \(left) rather than v10")
        }
    }
}

// MARK: - CF-9 · There is a way out that is not deletion

/// Settings had a prominent "Delete everything" and no export of any kind: no JSON, no CSV,
/// no markdown, no flag, no button. For a product whose pitch is that the memory is yours,
/// that asymmetry says leaving and destroying are the same act.
@Suite("CF-9 the memory can be taken elsewhere")
struct CF9ExportTests {

    @Test("CF-9 the archive carries every row, and says how many it carried")
    func archiveIsComplete() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            try await seed(store: store, captures: Fixtures.all(startingAt: TestClock.reference))
            _ = try await MemoryService(store: store, extractors: [RuleExtractor()]).consolidate(since: .distantPast)

            let live = try await store.stats()
            let archive = try await MemoryExport.archive(from: store)

            #expect(archive.counts.captures == live.captureCount, "captures were dropped")
            #expect(archive.captures.count == archive.counts.captures, "the count disagrees with the rows")
            #expect(archive.counts.sessions == live.sessionCount)
            #expect(archive.entities.count > 0, "nothing was learned, so this proves nothing")
            #expect(archive.provenance.count > 0, "the evidence behind each belief was left out")
            #expect(archive.format == MemoryExport.formatName)
        }
    }

    /// An export that silently drops rows is not an export. A deleted entity leaves with its
    /// flag set, so a reader can tell the difference rather than being handed a filtered view.
    @Test("CF-9 deleted entities leave too, flagged rather than filtered")
    func deletedEntitiesAreCarried() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            let entity = Entity(kind: .note, title: "A note the user removed", source: .authored)
            try await store.upsert(entity: entity)
            try await store.deleteEntity(id: entity.id)

            let archive = try await MemoryExport.archive(from: store)
            let found = archive.entities.first { $0.id == entity.id }
            #expect(found != nil, "a deleted row vanished from the export")
            #expect(found?.deleted == true, "it left without the flag that says what it is")
        }
    }

    /// The archive has to be readable by something that is not Memoir. Round-tripping through
    /// a plain `JSONDecoder` is the cheapest proof of that.
    @Test("CF-9 the JSON decodes without Memoir")
    func jsonRoundTrips() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            try await seed(store: store, captures: Fixtures.all(startingAt: TestClock.reference))
            _ = try await MemoryService(store: store, extractors: [RuleExtractor()]).consolidate(since: .distantPast)

            let data = try await MemoryExport.json(from: store)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let back = try decoder.decode(MemoryExport.Archive.self, from: data)

            #expect(back.formatVersion == MemoryExport.formatVersion)
            #expect(back.captures.count == back.counts.captures)
            #expect(!back.entities.isEmpty)
        }
    }

    /// The reading copy exists so a person can see what Memoir believes *and why*. A belief
    /// printed without its evidence is the thing this product refuses to hand anyone.
    @Test("CF-9 the markdown copy quotes the evidence under each belief")
    func markdownCarriesProvenance() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            try await seed(store: store, captures: Fixtures.all(startingAt: TestClock.reference))
            _ = try await MemoryService(store: store, extractors: [RuleExtractor()]).consolidate(since: .distantPast)

            let text = try await MemoryExport.markdown(from: store)
            let archive = try await MemoryExport.archive(from: store)

            #expect(text.hasPrefix("# Memoir memory"))
            #expect(text.contains("Where this came from:"), "no evidence was quoted at all")

            // Every non-deleted entity is named, and its authorship is stated.
            for entity in archive.entities where !entity.deleted {
                #expect(text.contains(entity.title), "\(entity.title) is missing from the export")
            }
            #expect(text.contains("yours") || text.contains("inferred"))
        }
    }

    @Test("CF-9 the extension picks the format, and the file is really written")
    func writeChoosesFormatByExtension() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            try await seed(store: store, captures: [Fixtures.email(at: TestClock.reference)])

            let directory = store.databaseURL.deletingLastPathComponent()
            let jsonURL = directory.appendingPathComponent("out.json")
            let markdownURL = directory.appendingPathComponent("out.md")

            _ = try await MemoryExport.write(from: store, to: jsonURL)
            _ = try await MemoryExport.write(from: store, to: markdownURL)

            let json = try String(contentsOf: jsonURL, encoding: .utf8)
            let markdown = try String(contentsOf: markdownURL, encoding: .utf8)
            #expect(json.hasPrefix("{"), "the .json file is not JSON")
            #expect(markdown.hasPrefix("# Memoir memory"), "the .md file is not the reading copy")
        }
    }

    /// Exporting is a read. It must not disturb the memory it is describing, least of all on
    /// the way out of the product.
    @Test("CF-9 exporting changes nothing")
    func exportIsReadOnly() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            try await seed(store: store, captures: Fixtures.all(startingAt: TestClock.reference))
            _ = try await MemoryService(store: store, extractors: [RuleExtractor()]).consolidate(since: .distantPast)

            let before = try await store.stats()
            _ = try await MemoryExport.json(from: store)
            _ = try await MemoryExport.markdown(from: store)
            let after = try await store.stats()

            #expect(before.captureCount == after.captureCount)
            #expect(before.entityCount == after.entityCount)
            #expect(before.sessionCount == after.sessionCount)
        }
    }
}

// MARK: - CF-5b · The system's own credential prompts

/// The exclusion list covered Keychain Access (the app you open) and missed the sheet macOS
/// puts in front of you. Measured on a real database before this suite existed: 40 captures
/// across `SecurityAgent`, `loginwindow` and `UserNotificationCenter`, 23 of them holding the
/// text of a credential prompt, one reading "enter the login keychain password".
@Suite("CF-5b system credential prompts are never captured")
struct CF5bCredentialPromptTests {

    @Test("CF-5b the credential surfaces ship excluded")
    func credentialSurfacesAreExcluded() {
        let config = CaptureConfig()
        for bundleID in ["com.apple.SecurityAgent", "com.apple.loginwindow", "com.apple.UserNotificationCenter"] {
            #expect(config.isExcluded(bundleID), "\(bundleID) is readable by default")
        }
    }

    /// Adding to the default list only ever helps the next person to install: the exclusion
    /// set is persisted whole, so an existing `config.json` keeps the list it was born with.
    @Test("CF-5b an older config.json is seeded with the identifiers added since")
    func olderConfigGainsNewExclusions() throws {
        // A file written before exclusion revisions existed: no revision key at all.
        let legacy = """
        {
          "intervalSeconds": 6,
          "idleThresholdSeconds": 120,
          "captureWindowTitles": true,
          "maxTextLength": 20000,
          "excludedBundleIDs": ["com.1password.1password"]
        }
        """
        let config = try JSONDecoder().decode(CaptureConfig.self, from: Data(legacy.utf8))

        #expect(config.isExcluded("com.apple.SecurityAgent"), "the fix never reached an existing install")
        #expect(config.isExcluded("com.apple.loginwindow"))
        #expect(config.isExcluded("com.1password.1password"), "the user's own list was discarded")
        #expect(config.exclusionsRevision == CaptureConfig.currentExclusionsRevision)
    }

    /// `intervalSeconds` was retired when capture stopped running on a timer. Every installed
    /// copy has it written into `config.json`, so decoding has to shrug it off rather than throw:
    /// a config file that fails to load takes the exclusion list down with it, and an exclusion
    /// list that fails to load is a password manager being read from.
    @Test("CF-5b a config.json holding the retired interval key still loads, exclusions and all")
    func retiredIntervalKeyIsIgnored() throws {
        let withRetiredKey = """
        {
          "intervalSeconds": 45,
          "idleThresholdSeconds": 300,
          "captureWindowTitles": false,
          "maxTextLength": 12000,
          "exclusionsRevision": 2,
          "excludedBundleIDs": ["com.example.private"]
        }
        """
        let config = try JSONDecoder().decode(CaptureConfig.self, from: Data(withRetiredKey.utf8))

        #expect(config.isExcluded("com.example.private"), "the user's own list was discarded")
        #expect(config.effectiveIdleThreshold == 300, "the settings either side of it were lost")
        #expect(config.captureWindowTitles == false)
        #expect(config.effectiveMaxTextLength == 12_000)
    }

    /// Seeding once, not on every launch. Settings → Capture can remove an exclusion, and
    /// re-adding it each time the app starts would quietly overrule a deliberate choice,
    /// the same sin as letting extraction overwrite a correction.
    @Test("CF-5b a removal at the current revision is obeyed, not re-seeded")
    func removalAtCurrentRevisionSticks() throws {
        var config = CaptureConfig()
        config.excludedBundleIDs.remove("com.apple.UserNotificationCenter")

        let round = try JSONDecoder().decode(
            CaptureConfig.self, from: try JSONEncoder().encode(config))

        #expect(!round.isExcluded("com.apple.UserNotificationCenter"), "the user's removal was undone")
        #expect(round.isExcluded("com.apple.SecurityAgent"), "an untouched default was lost")
    }

    /// Excluding an app stops it being read from that moment. Everything already recorded
    /// stays, which is no use when the reason for the exclusion is that it should never have
    /// been read at all.
    @Test("CF-5b captures already taken from those apps can be retired, quotes and all")
    func existingCredentialCapturesAreRemovable() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            let text = "security codesign wants to access key \"memoir\" in your keychain. "
                + "To allow this, enter the \"login\" keychain password. Password:"
            let prompt = CaptureEvent(
                ts: TestClock.reference,
                appBundleID: "com.apple.SecurityAgent",
                appName: "SecurityAgent",
                windowTitle: nil,
                text: text,
                textHash: AccessibilityCapture.textHash(text)
            )
            try await seed(store: store, captures: [prompt, Fixtures.email(at: TestClock.days(1))])
            #expect(try await store.stats().captureCount == 2)

            let removed = try await store.purge(
                fromBundleIDs: CaptureConfig.exclusionsAdded(since: 1))
            #expect(removed == 1, "removed \(removed) rows")

            let remaining = try await store.stats().captureCount
            #expect(remaining == 1, "the unrelated capture was taken too")

            // And the bytes are gone, not merely unlinked from a query.
            let bytes = ws.databaseBytes()
            #expect(
                bytes.range(of: Data("keychain password".utf8)) == nil,
                "the credential prompt is still in the file"
            )
        }
    }

    /// A memory must not hold an application among the user's projects.
    ///
    /// Chrome ends every window title with "— Google Chrome", so the Title-Case rule eventually
    /// read one of them as a project name. That one row — inferred, one title-only sighting,
    /// minted in a single afternoon — went on to match 47.3% of every capture in the corpus.
    ///
    /// The matcher now refuses to let it label anything, and this stops it existing. Both are
    /// needed: an entry reading "Google Chrome" in the list of things the user works on is
    /// wrong even on a day it bills nothing.
    @Test("CF-5g an application never becomes a project")
    func anApplicationNeverBecomesAProject() {
        let capture = Fixtures.capture(
            text: "some page content", app: "Google Chrome", bundleID: "com.google.Chrome",
            windowTitle: "Some page \u{2014} Google Chrome", at: TestClock.reference, name: "c1")

        var builder = ExtractionBuilder()
        let rejected = builder.add(
            kind: .project, title: "Google Chrome", confidence: 0.9,
            capture: capture, snippet: "Google Chrome")
        #expect(rejected == nil, "the browser was minted as a project")

        // Case-and-spacing insensitive, because the title rule does not preserve either.
        #expect(builder.add(
            kind: .project, title: "google  chrome", confidence: 0.9,
            capture: capture, snippet: "google chrome") == nil)

        // A real project read in that app is untouched.
        let kept = builder.add(
            kind: .project, title: "Fenwick Migration", confidence: 0.9,
            capture: capture, snippet: "Fenwick Migration")
        #expect(kept != nil, "a real project seen in a browser must still be recorded")

        // And the guard is about projects. A person or a note named after an app is a
        // different question and this rule does not answer it.
        #expect(builder.add(
            kind: .note, title: "Google Chrome", confidence: 0.5,
            capture: capture, snippet: "Google Chrome") != nil)

        let result = builder.build()
        #expect(
            !result.entities.contains { $0.kind == .project && $0.title.contains("Chrome") },
            "a project named after the browser survived the pass")
    }

    /// Half of what a capture can be cited from was never on the screen.
    ///
    /// A capture is a whole accessibility tree: a window title, whatever was inside the
    /// viewport, and often two thousand more characters of navigation, sidebar, comments and
    /// footer. Measured on a real vault, only about half of stored characters sat inside the
    /// window. Citing all of it in one voice tells the reader that a match in the title and a
    /// match in the footer are the same fact.
    ///
    /// The grade is about POSITION, not confidence: where the words were is something the
    /// capture already knows, and a confidence number would be a guess dressed as arithmetic.
    @Test("CF-5e evidence carries where on the screen it came from")
    func evidenceCarriesItsStrength() async throws {
        let onScreen = "The Fenwick migration cutover ran clean on Tuesday night."
        let buried = String(repeating: "unrelated navigation and footer text. ", count: 30)
            + "a passing mention of the Fenwick migration in a related-links rail."

        // In the viewport: the screen speaking.
        let visible = CaptureEvent(
            ts: TestClock.reference, appBundleID: "com.google.Chrome", appName: "Google Chrome",
            windowTitle: "notes", text: onScreen + " " + buried,
            textHash: "h1", visibleText: onScreen)
        #expect(ExtractionBuilder.strength(of: "Fenwick migration cutover", in: visible) == .direct)

        // Present, but outside the viewport: true and possibly furniture.
        #expect(ExtractionBuilder.strength(of: "related-links rail", in: visible) == .incidental)

        // The window title always counts, whatever the viewport says.
        let titled = CaptureEvent(
            ts: TestClock.reference, appBundleID: "com.google.Chrome", appName: "Google Chrome",
            windowTitle: "Fenwick Migration — notes", text: buried,
            textHash: "h2", visibleText: "")
        #expect(ExtractionBuilder.strength(of: "Fenwick Migration", in: titled) == .direct)

        // An unresolved viewport must not demote everything on the capture: the opening of
        // the body is what the matcher itself reads, so it stands in.
        let noGeometry = CaptureEvent(
            ts: TestClock.reference, appBundleID: "com.google.Chrome", appName: "Google Chrome",
            windowTitle: nil, text: onScreen + " " + buried, textHash: "h3", visibleText: nil)
        #expect(ExtractionBuilder.strength(of: "cutover ran clean", in: noGeometry) == .direct)
        #expect(ExtractionBuilder.strength(of: "related-links rail", in: noGeometry) == .incidental)
    }

    /// The grade survives the round trip, and an ungraded row reads as the screen speaking.
    @Test("CF-5f a row written before the grade existed reads as direct")
    func ungradedProvenanceReadsAsDirect() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            let entity = Entity(kind: .project, title: "Fenwick Migration")
            try await store.upsert(entity: entity)
            try await store.add(provenance: Provenance(
                entityID: entity.id, captureID: "c1", field: "title",
                snippet: "seen in a footer", ts: TestClock.reference, strength: .incidental))
            try await store.add(provenance: Provenance(
                entityID: entity.id, captureID: "c2", field: "title",
                snippet: "seen in the title", ts: TestClock.reference))

            let rows = try await store.provenance(entityID: entity.id)
            let byCapture = Dictionary(uniqueKeysWithValues: rows.map { ($0.captureID, $0.strength) })
            #expect(byCapture["c1"] == .incidental, "the grade did not survive the round trip")
            #expect(byCapture["c2"] == .direct, "the default must be the screen speaking")
        }
    }

    /// The retirement has to take the sessions too, and for a long time it did not.
    ///
    /// Found on a real installation: `com.apple.SecurityAgent`, `com.apple.loginwindow` and
    /// `com.apple.UserNotificationCenter` held zero captures — CF-5b's purge had run and
    /// worked — and 443 session rows totalling 77.5 hours, one of them a credential sheet
    /// frontmost for 596 seconds. Text was the only thing anyone thought to delete, so the
    /// durable record of *when the password box was in front of you, and for how long*
    /// survived a purge whose entire purpose was that it should not have been recorded.
    ///
    /// Note what this test does NOT do: it never adds the app in Settings. Excluding an app
    /// there deliberately purges nothing (`runLaunchCleanup` passes only
    /// `exclusionsAdded(since:)`), because a checkbox that retroactively deletes history the
    /// user was never warned about is a worse bug than the one being fixed here. Driving this
    /// through Settings would either not work or get "fixed" by purging the whole exclusion
    /// list, so it calls the store directly and on purpose.
    @Test("CF-5c retiring an app takes its sessions, not just its text")
    func retiringAnAppTakesItsSessions() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            let excluded = "com.apple.SecurityAgent"

            let text = "To allow this, enter the \"login\" keychain password. Password:"
            try await seed(store: store, captures: [
                CaptureEvent(
                    ts: TestClock.reference,
                    appBundleID: excluded,
                    appName: "SecurityAgent",
                    windowTitle: nil,
                    text: text,
                    textHash: AccessibilityCapture.textHash(text)
                ),
                Fixtures.email(at: TestClock.days(1)),
            ])
            // The 596-second credential sheet, and an unrelated session that must survive.
            try await store.upsert(session: Session(
                appBundleID: excluded,
                appName: "SecurityAgent",
                startedAt: TestClock.reference,
                endedAt: TestClock.reference.addingTimeInterval(596)
            ))
            try await store.upsert(session: Session(
                appBundleID: "com.apple.Safari",
                appName: "Safari",
                startedAt: TestClock.days(1),
                endedAt: TestClock.days(1).addingTimeInterval(300)
            ))

            let removed = try await store.purge(fromBundleIDs: CaptureConfig.exclusionsAdded(since: 1))
            #expect(removed == 1, "the return value counts captures only, got \(removed)")

            let sessions = try await store.sessions(from: .distantPast, to: .distantFuture)
            #expect(
                sessions.allSatisfy { $0.appBundleID != excluded },
                "the retired app still has \(sessions.filter { $0.appBundleID == excluded }.count) sessions"
            )
            #expect(sessions.count == 1, "an unrelated app's session was taken too")

            let bytes = ws.databaseBytes()
            #expect(
                bytes.range(of: Data(excluded.utf8)) == nil,
                "the retired bundle identifier is still somewhere in the file"
            )
        }
    }

    /// The case the live database was actually in: text already purged by an earlier build,
    /// sessions left behind. The second pass must still find work to do and still reach the
    /// disk, which it will not if the checkpoint is gated on the capture count alone.
    @Test("CF-5d a second pass still retires sessions when the captures are already gone")
    func secondPassRetiresOrphanedSessions() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            let excluded = "com.apple.loginwindow"

            try await store.upsert(session: Session(
                appBundleID: excluded,
                appName: "loginwindow",
                startedAt: TestClock.reference,
                endedAt: TestClock.reference.addingTimeInterval(1_800)
            ))
            #expect(try await store.stats().captureCount == 0, "this test is about the no-captures case")

            let removed = try await store.purge(fromBundleIDs: CaptureConfig.exclusionsAdded(since: 1))
            #expect(removed == 0, "there were no captures to count")

            let sessions = try await store.sessions(from: .distantPast, to: .distantFuture)
            #expect(sessions.isEmpty, "\(sessions.count) orphaned sessions survived the purge")

            let bytes = ws.databaseBytes()
            #expect(
                bytes.range(of: Data(excluded.utf8)) == nil,
                "the bytes are still on disk: the checkpoint did not run"
            )
        }
    }
}

// MARK: - Helpers owned by this file

/// Wraps another extractor and rewrites what it proposes, so consolidation can be re-run with
/// deliberately "better" evidence than the user's own correction.
///
/// The title is left alone on purpose: `RuleExtractor` derives an entity's id from its
/// normalised title, so changing it here would produce a genuinely different entity and the
/// test would prove nothing. Everything a merge is allowed to touch (confidence, detail, due
/// date) is what gets rewritten.
private struct RewritingExtractor: Extractor {
    let base: any Extractor
    let confidence: Double
    let detail: String
    let dueAt: Date?

    func extract(from captures: [CaptureEvent]) async throws -> ExtractionResult {
        let pass = try await base.extract(from: captures)
        let rewritten = pass.entities.map { entity -> Entity in
            var copy = entity
            copy.confidence = confidence
            copy.detail = detail
            if entity.kind == .commitment { copy.dueAt = dueAt }
            return copy
        }
        return ExtractionResult(entities: rewritten, provenance: pass.provenance)
    }
}

// `RouterBackedBrain` used to live here as a private test helper. It is `MemoirKit`'s now
// (Sources/MemoirKit/Brain/RouterBackedBrain.swift), because the app and `memoir-ask --reindex`
// need exactly the same thing: `LLMExtractor` takes a brain, not a router, and handing it a
// concrete brain would route around the `allowCloud` veto at the stage that reads the most.
// This test therefore now exercises the same type the product runs, which is the point of CF-2.

/// A `CaptureSource` that hands back a scripted queue of events and counts how often it was
/// asked. The count is the whole point in CF-5: an excluded app must never reach it.
private final class TrustCaptureSpy: CaptureSource, @unchecked Sendable {
    private let lock = NSLock()
    private var queue: [CaptureEvent]
    private var callCount = 0

    init(events: [CaptureEvent]) {
        self.queue = events
    }

    func snapshot() async throws -> CaptureEvent? {
        lock.withLock {
            callCount += 1
            return queue.isEmpty ? nil : queue.removeFirst()
        }
    }

    /// How many times the loop asked for a snapshot.
    var calls: Int { lock.withLock { callCount } }
}

/// A mutable frontmost-app script, so a test can switch apps between two ticks.
private final class TrustFrontmostScript: @unchecked Sendable {
    private let lock = NSLock()
    private var value: FrontmostApp?

    init(_ initial: FrontmostApp?) {
        self.value = initial
    }

    var current: FrontmostApp? { lock.withLock { value } }

    func set(_ next: FrontmostApp?) { lock.withLock { value = next } }
}

/// A synthetic accessibility node that records every read made of it.
///
/// `readTexts()` and `readChildren()` stand in for the attribute and children reads
/// `AXScraper` performs. Counting them is what turns "the password did not appear in the
/// output" into the stronger "the password was never read and its subtree was never entered".
private final class TrustAXNode: @unchecked Sendable {
    let name: String
    let isSecure: Bool

    private let lock = NSLock()
    private let texts: [String]
    private let children: [TrustAXNode]
    private var textReadCount = 0
    private var childReadCount = 0

    init(name: String, texts: [String], children: [TrustAXNode] = [], isSecure: Bool = false) {
        self.name = name
        self.texts = texts
        self.children = children
        self.isSecure = isSecure
    }

    func readTexts() -> [String] {
        lock.withLock {
            textReadCount += 1
            return texts
        }
    }

    func readChildren() -> [TrustAXNode] {
        lock.withLock {
            childReadCount += 1
            return children
        }
    }

    /// How many times this node's text attributes were read.
    var textReads: Int { lock.withLock { textReadCount } }

    /// How many times this node was asked for its children.
    var childReads: Int { lock.withLock { childReadCount } }
}

/// Deterministic captures with bodies large enough that failing to vacuum is visible on disk.
///
/// Every row is unique, so nothing dedupes, and every row contains the word `purgeable`, which
/// CF-7 greps for both through the search API and in the raw bytes.
private func fatCaptures(count: Int, from start: Date = TestClock.reference) -> [CaptureEvent] {
    (0..<count).map { i in
        let index = String(format: "%04d", i)
        let body = (0..<40).map { line in
            "row \(index) line \(line) purgeable filler text for the retention and vacuum flow"
        }.joined(separator: "\n")
        return CaptureEvent(
            id: TestID.stable("cf7-fat", index),
            ts: start.addingTimeInterval(Double(i) * 60),
            appBundleID: "sh.memoir.tests.bulk",
            appName: "Bulk",
            windowTitle: "pane \(index)",
            text: body,
            textHash: AccessibilityCapture.textHash(body)
        )
    }
}

/// Row counts of both full-text indexes, read with a private read-only connection.
///
/// Returns `nil` when this SQLite build has no FTS5 and the tables were never created, which
/// `Store` degrades to a `LIKE` scan rather than failing to open.
///
/// The connection opened here is independent of any `Store`, so it reads whatever is on disk.
private func ftsCounts(at url: URL) throws -> (captures: Int, entities: Int)? {
    var handle: OpaquePointer?
    guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db = handle else {
        if let handle { sqlite3_close_v2(handle) }
        throw MemoirError.storage("CF-7 could not open \(url.path) read-only")
    }
    defer { sqlite3_close_v2(db) }

    func scalar(_ sql: String) -> Int? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return nil }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    let present = scalar(
        """
        SELECT COUNT(*) FROM sqlite_master
        WHERE type = 'table' AND name IN ('captures_fts', 'entities_fts')
        """
    )
    guard present == 2 else { return nil }

    guard let captures = scalar("SELECT COUNT(*) FROM captures_fts"),
          let entities = scalar("SELECT COUNT(*) FROM entities_fts")
    else {
        throw MemoirError.storage("CF-7 could not count the FTS tables")
    }
    return (captures, entities)
}

/// A byte-level snapshot of `UserDefaults`, for CF-4 to grep.
///
/// The real preferences plist is not written into the workspace, so what is searched is the
/// live standard domain, serialised as a binary plist where possible, and as its textual
/// description as well, so a value of an odd type cannot hide a leak.
private func userDefaultsBytes() -> Data {
    let representation = UserDefaults.standard.dictionaryRepresentation()
    var out = Data()
    let serialisable = representation.filter {
        PropertyListSerialization.propertyList($0.value, isValidFor: .binary)
    }
    if let plist = try? PropertyListSerialization.data(
        fromPropertyList: serialisable,
        format: .binary,
        options: 0
    ) {
        out.append(plist)
    }
    out.append(Data(String(describing: representation).utf8))
    return out
}

@Suite("CF-8 private browsing is never captured")
struct PrivateBrowsingTests {

    @Test("CF-8 private windows are recognised across browsers and languages")
    func privateWindowsRecognised() {
        // Private browsing is the clearest signal a user can give that something should not
        // be remembered. The browser only stops recording its OWN history; nothing stops an
        // accessibility reader, so this has to be honoured explicitly. Screenpipe documents
        // recording incognito by default; Memoir does not.
        let privateTitles = [
            "Some Page - Google Chrome (Incognito)",
            "Example \u{2014} Private Browsing",
            "Safari (Private)",
            "Edge InPrivate browsing",
            "Qualcosa - Navigazione in incognito",
            "Quelque chose \u{2014} Navigation privée",
            "Algo - Modo incógnito",
            "Etwas \u{2014} Privates Fenster",
        ]
        for title in privateTitles {
            #expect(AccessibilityCapture.isPrivateBrowsing(title),
                    "\(title) should be recognised as private browsing")
        }
    }

    @Test("CF-8 ordinary windows are unaffected")
    func ordinaryWindowsStillCaptured() {
        // This must never suppress normal capture: an unrecognised phrase means capture,
        // so the check can only be extended, never silently broken.
        for title in ["GitHub - Google Chrome", "Inbox \u{2014} Mail", "Architecture - Obsidian",
                      "Private equity report - Numbers", "Privacy Policy - Chrome"] {
            #expect(AccessibilityCapture.isPrivateBrowsing(title) == false,
                    "\(title) is not a private window")
        }
    }

    // MARK: - CF-7b · a migration never destroys what it cannot restore

    @Test("CF-7b a schema change snapshots the database first")
    func migrationBacksUpFirst() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            try await store.insert(capture: CaptureEvent(
                ts: TestClock.reference, appBundleID: "a", appName: "A",
                windowTitle: "t", text: "something worth keeping", textHash: "h1"))
            await store.close()

            // Wind the version back so reopening replays a real migration.
            let path = store.databaseURL.path
            var db: OpaquePointer?
            #expect(sqlite3_open(path, &db) == SQLITE_OK)
            sqlite3_exec(db, "PRAGMA user_version = \(Schema.version - 1);", nil, nil, nil)
            sqlite3_close_v2(db)

            let reopened = try Store(path: store.databaseURL, mayMigrate: true)
            let backup = path + ".v\(Schema.version - 1).backup"
            #expect(FileManager.default.fileExists(atPath: backup),
                    "a migration must snapshot before it changes shape")

            // The snapshot has to be READABLE, not just present. A backup nobody can open is
            // the same as no backup, discovered at the worst possible moment. Opened with raw
            // SQLite rather than through Store, because Store refuses a schema older than the
            // build understands - which every backup is, by definition.
            var check: OpaquePointer?
            #expect(sqlite3_open_v2(backup, &check, SQLITE_OPEN_READONLY, nil) == SQLITE_OK)
            var stmt: OpaquePointer?
            #expect(sqlite3_prepare_v2(check, "SELECT COUNT(*) FROM captures;", -1, &stmt, nil) == SQLITE_OK)
            #expect(sqlite3_step(stmt) == SQLITE_ROW)
            #expect(sqlite3_column_int(stmt, 0) == 1, "the snapshot must contain the capture")
            sqlite3_finalize(stmt)
            sqlite3_close_v2(check)
            await reopened.close()
        }
    }

    @Test("CF-7b a second run does not clobber the good snapshot")
    func backupIsNotOverwritten() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            await store.close()
            let path = store.databaseURL.path
            let backup = path + ".v\(Schema.version - 1).backup"

            for _ in 0..<2 {
                var db: OpaquePointer?
                sqlite3_open(path, &db)
                sqlite3_exec(db, "PRAGMA user_version = \(Schema.version - 1);", nil, nil, nil)
                sqlite3_close_v2(db)
                let s = try Store(path: store.databaseURL, mayMigrate: true)
                await s.close()
            }
            // An upgrade that runs twice must not replace the good copy with a
            // half-migrated one.
            #expect(FileManager.default.fileExists(atPath: backup))
        }
    }

    @Test("CF-7c a tool may not change the schema, only the app may")
    func migrationNeedsConsent() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            await store.close()
            let path = store.databaseURL.path
            var db: OpaquePointer?
            sqlite3_open(path, &db)
            sqlite3_exec(db, "PRAGMA user_version = \(Schema.version - 1);", nil, nil, nil)
            sqlite3_close_v2(db)

            // A developer tool migrated the user's live database from v3 to v4. The installed
            // app was a v3 build, refused to open it, and quit with "Memoir can't start" over a
            // database that was completely intact.
            #expect(throws: MemoirError.self) {
                _ = try Store(path: store.databaseURL)
            }
            // The version is untouched by the refusal: refusing must not half-do it.
            var check: OpaquePointer?
            sqlite3_open(path, &check)
            var stmt: OpaquePointer?
            sqlite3_prepare_v2(check, "PRAGMA user_version;", -1, &stmt, nil)
            sqlite3_step(stmt)
            #expect(sqlite3_column_int(stmt, 0) == Schema.version - 1)
            sqlite3_finalize(stmt); sqlite3_close_v2(check)

            // The app asks, and gets it.
            let upgraded = try Store(path: store.databaseURL, mayMigrate: true)
            await upgraded.close()
        }
    }

    @Test("CF-7c a fresh database still initialises without asking")
    func freshDatabaseNeedsNoConsent() async throws {
        try await TestWorkspace.with { ws in
            // Creation is not migration: there is nothing anyone could lose.
            let fresh = try Store(path: ws.root.appendingPathComponent("new.sqlite"))
            #expect(try await fresh.stats().captureCount == 0)
            await fresh.close()
        }
    }

    @Test("CF-7c a newer database is read, not refused")
    func newerSchemaIsNotFatal() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            try await store.insert(capture: CaptureEvent(
                ts: TestClock.reference, appBundleID: "a", appName: "A",
                windowTitle: "t", text: "still here", textHash: "h"))
            await store.close()
            var db: OpaquePointer?
            sqlite3_open(store.databaseURL.path, &db)
            sqlite3_exec(db, "PRAGMA user_version = \(Schema.version + 5);", nil, nil, nil)
            sqlite3_close_v2(db)

            // "Memoir can't start" over a perfect database is a policy choice, and it was the
            // wrong one. Migrations are additive by rule, so every column this build knows is
            // still there.
            let readable = try Store(readOnlyPath: store.databaseURL)
            #expect(try await readable.stats().captureCount == 1)
            await readable.close()
        }
    }

    @Test("CF-7c a newer database opens READ-WRITE too, not only read-only")
    func newerSchemaOpensForWritingAsWell() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            try await store.insert(capture: CaptureEvent(
                ts: TestClock.reference, appBundleID: "a", appName: "A",
                windowTitle: "t", text: "intact", textHash: "h"))
            await store.close()
            var db: OpaquePointer?
            sqlite3_open(store.databaseURL.path, &db)
            sqlite3_exec(db, "PRAGMA user_version = \(Schema.version + 1);", nil, nil, nil)
            sqlite3_close_v2(db)

            // The half I missed the first time. I made the read-only path tolerate a newer
            // schema, reported CF-7c as fixed, and left this path throwing - so it bricked
            // again the moment a newer build touched the database first. Two paths, one flow.
            let reopened = try Store(path: store.databaseURL, mayMigrate: true)
            #expect(try await reopened.stats().captureCount == 1)
            // And it must NOT have written v4 shapes into a v5 file.
            var check: OpaquePointer?
            sqlite3_open(store.databaseURL.path, &check)
            var stmt: OpaquePointer?
            sqlite3_prepare_v2(check, "PRAGMA user_version;", -1, &stmt, nil)
            sqlite3_step(stmt)
            #expect(sqlite3_column_int(stmt, 0) == Schema.version + 1, "must not downgrade the file")
            sqlite3_finalize(stmt); sqlite3_close_v2(check)
            await reopened.close()
        }
    }
}
