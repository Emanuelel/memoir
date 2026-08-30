//
//  AuthoredTests.swift
//  CF-54: Authored beats inferred, always.
//  CF-55: Authored entities are visibly distinct.
//  CF-56: Completing is permanent.
//
//  ─────────────────────────────────────────────────────────────────────────────
//  Nothing here is mocked. The store is a real SQLite file, the extractor is the
//  real `RuleExtractor`, and the merge under test is the one production runs.
//
//  Two layers, because either alone leaves a hole:
//
//  1. `MemoryMerge.merged` directly, where the law lives and where both argument
//     orders can be exercised. A store test can only ever show one of them.
//  2. Whole consolidation passes over a real capture, which is the only way to
//     prove the law is actually reached: a merge policy nothing calls protects
//     nothing.
//  ─────────────────────────────────────────────────────────────────────────────
//

import Foundation
import Testing

import MemoirFixtures
@testable import MemoirKit

// MARK: - Harness

/// The commitments this file is built around, each in both of its versions.
///
/// The user pushed one in their own words and later typed the same sentence into a note that
/// Memoir captured. That overlap is the whole point: an authored row and an inferred one are
/// only ever in danger of merging when they share a dedupe key, so a test whose two versions
/// do not collide proves nothing at all.
private enum AuthoredPush {

    /// The user's own wording, and the sentence the capture below contains verbatim.
    static let sentence = "Send the signed lease scan to Elena by Friday"

    /// What the user typed, exactly as the push path stores it: their words, their due date.
    ///
    /// Thursday 09:00 local, deliberately not the Friday 17:00 the date resolver produces
    /// from the same sentence, so an overwrite by extraction would be visible rather than
    /// coincidentally identical.
    static let authoredDueAt = TestClock.local(2026, 3, 19, 9, 0)

    /// The detail only the user could know. Extraction has no way to produce this string,
    /// so finding anything else in the field means a guess got through.
    static let authoredDetail = "The agent needs the scan itself, not a photo of it."

    /// The authored commitment as the push path would have written it.
    static func commitment(
        confidence: Double = 0.6,
        deleted: Bool = false,
        at ts: Date = TestClock.reference
    ) -> Entity {
        Entity(
            id: TestID.stable("push", "lease-scan"),
            kind: .commitment,
            title: sentence,
            detail: authoredDetail,
            dueAt: authoredDueAt,
            confidence: confidence,
            pinned: false,
            corrected: false,
            deleted: deleted,
            source: .authored,
            createdAt: ts,
            updatedAt: ts
        )
    }

    /// A note containing the user's sentence word for word, plus a heading and one further
    /// line, neither of which trips a rule, so the pass produces exactly one rival.
    ///
    /// The window title deliberately does not contain the sentence: `RuleExtractor` drops a
    /// segment that its own window title repeats, on the grounds that it is a heading.
    static func capture(at ts: Date = TestClock.reference) -> CaptureEvent {
        Fixtures.capture(
            text: """
            Flat move

            \(sentence)
            Deposit is with the previous agency
            """,
            app: "Notes",
            bundleID: "com.apple.Notes",
            windowTitle: "Flat move",
            at: ts,
            name: "push-lease-note"
        )
    }

    /// The pair the decisive test turns on: two commitments the user left bare, differing in
    /// nothing but who wrote them.
    ///
    /// A push carries only what was said. "Remind me to send the signed lease scan to Elena"
    /// names no day, and CF-52 forbids the parse from inventing one, so an authored row with
    /// an empty `dueAt` and no detail is the normal case rather than a corner of one.
    static let bareTitles = (
        authored: "Send the signed lease scan to Elena",
        control: "Chase the deposit from the previous agency"
    )

    /// One of those rows: no date, no detail, nothing for a guess to agree with.
    static func bare(title: String, source: EntitySource) -> Entity {
        Entity(
            id: TestID.stable("bare", title),
            kind: .commitment,
            title: title,
            detail: nil,
            dueAt: nil,
            confidence: 0.6,
            source: source,
            createdAt: TestClock.reference,
            updatedAt: TestClock.reference
        )
    }

    /// A note carrying both bare sentences word for word, so provenance written during the
    /// pass points at text that genuinely says what it claims.
    static func bareCapture(at ts: Date = TestClock.reference) -> CaptureEvent {
        Fixtures.capture(
            text: """
            Flat move

            \(bareTitles.authored)
            \(bareTitles.control)
            """,
            app: "Notes",
            bundleID: "com.apple.Notes",
            windowTitle: "Flat move",
            at: ts,
            name: "push-bare-note"
        )
    }

    /// The detail and the due date a model supplies for a bare sentence. Neither was ever
    /// said out loud, which is exactly why finding them on the authored row is a failure.
    static let proposedDetail = "Deadline in Notes"
    static let proposedDueAt = TestClock.local(2026, 3, 20, 17, 0)

    /// What extraction proposes for one of those sentences: the same title, plus the two
    /// fields the user never gave.
    static func proposal(for title: String, confidence: Double = 0.9) -> Entity {
        Entity(
            id: MemoryText.stableID("entity", EntityKind.commitment.rawValue, MemoryText.normalizedTitle(title)),
            kind: .commitment,
            title: title,
            detail: proposedDetail,
            dueAt: proposedDueAt,
            confidence: confidence,
            source: .inferred,
            createdAt: TestClock.days(1),
            updatedAt: TestClock.days(1)
        )
    }

    /// What extraction proposes for that same sentence: same dedupe key, everything else
    /// different and more confident than what the user typed.
    static func inferredRival(
        confidence: Double = 0.95,
        title: String = sentence,
        at ts: Date = TestClock.days(1)
    ) -> Entity {
        Entity(
            id: MemoryText.stableID("entity", EntityKind.commitment.rawValue, MemoryText.normalizedTitle(title)),
            kind: .commitment,
            title: title,
            detail: "Deadline in Notes",
            dueAt: TestClock.days(40),
            confidence: confidence,
            pinned: false,
            corrected: false,
            deleted: false,
            source: .inferred,
            createdAt: ts,
            updatedAt: ts
        )
    }
}

/// Stands in for the LLM extractor: a pass that proposes commitments for titles it was told
/// about, each helpfully carrying a deadline and a detail the user never gave.
///
/// Hand-built rather than derived from the note, because the fields a merge can actually
/// reach are the empty ones, and `RuleExtractor` cannot be made to propose a *dateless*
/// sentence and a dated one under the same title. `LLMExtractor` produces exactly this
/// shape: free-form titles, a supplied detail, and a date it resolved from surrounding text.
private struct ProposingExtractor: Extractor {
    let titles: [String]
    let detail: String
    let dueAt: Date
    let confidence: Double

    func extract(from captures: [CaptureEvent]) async throws -> ExtractionResult {
        guard let capture = captures.first else { return .empty }
        var builder = ExtractionBuilder()
        for title in titles {
            builder.add(
                kind: .commitment,
                title: title,
                detail: detail,
                dueAt: dueAt,
                confidence: confidence,
                capture: capture,
                snippet: title
            )
        }
        return builder.build()
    }
}

/// Wraps another extractor and rewrites everything a merge is allowed to touch, so a
/// consolidation pass can be re-run with deliberately "better" evidence than the user's own.
///
/// Titles are left alone on purpose: the title is half the dedupe key, so changing it here
/// would produce a genuinely different entity and the collision under test would evaporate.
private struct OverconfidentExtractor: Extractor {
    let base: any Extractor
    let confidence: Double
    let detail: String
    let dueAt: Date

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

// MARK: - CF-54 · Authored beats inferred, always

/// CF-1 extended from correction to creation.
///
/// A correction is the user disagreeing with a guess; an authored row was never a guess in
/// the first place, so there is nothing in it for extraction to improve. Attacked from both
/// merge orders, through repetition, against a near-certain rival, at the source flag, and
/// on a row the user has finished with.
///
/// The decisive case is ``bareAuthoredFieldsAreNeverFilled()``, and for the same reason CF-1's
/// is: the merge below the guard never rewrites a field that already has a value, it only
/// fills empty ones. Every populated-row test here therefore still passes with the authored
/// check deleted. Empty fields are the only thing the guard actually stands in front of, and
/// on an authored row they are the common case, not the corner.
@Suite("CF-54 · authored beats inferred")
struct CF54AuthoredTests {

    // MARK: The law, at the merge itself

    @Test("CF-54 an inferred candidate cannot move an authored title, detail or due date")
    func inferredNeverOverwritesAuthored() {
        let authored = AuthoredPush.commitment()
        let rival = AuthoredPush.inferredRival(title: "send the signed lease scan to elena by friday!!!")

        #expect(
            MemoryText.dedupeKey(kind: .commitment, title: rival.title)
                == MemoryText.dedupeKey(kind: .commitment, title: authored.title),
            "the two spellings must normalise identically or this test proves nothing"
        )

        let (merged, changed) = MemoryMerge.merged(
            existing: authored,
            candidate: rival,
            now: TestClock.days(2)
        )

        #expect(merged.title == AuthoredPush.sentence, "the guess rewrote the user's own words")
        #expect(merged.detail == AuthoredPush.authoredDetail)
        #expect(merged.dueAt == AuthoredPush.authoredDueAt, "the guess moved a due date the user set")
        #expect(merged.kind == .commitment)
        #expect(merged.source == .authored)
        #expect(!merged.deleted)
        #expect(merged.confidence > authored.confidence, "corroboration must still raise confidence")
        #expect(changed, "a confidence rise is a change and must be reported as one")
    }

    @Test("CF-54 fields an authored row left empty are never filled by extraction")
    func bareAuthoredFieldsAreNeverFilled() {
        let authored = AuthoredPush.bare(title: AuthoredPush.bareTitles.authored, source: .authored)
        let control = AuthoredPush.bare(title: AuthoredPush.bareTitles.control, source: .inferred)

        let (kept, _) = MemoryMerge.merged(
            existing: authored,
            candidate: AuthoredPush.proposal(for: authored.title),
            now: TestClock.days(1)
        )
        #expect(kept.detail == nil, "extraction wrote \"\(kept.detail ?? "")\" into a field the user left blank")
        #expect(
            kept.dueAt == nil,
            "extraction gave the user a deadline of \(kept.dueAt.map(TestClock.iso) ?? "nil") that they never set"
        )
        #expect(kept.source == .authored)

        // The control is the same shape with `source` flipped, met by the same candidate. If
        // it does not come back filled then the merge was never offering anything and the
        // assertions above are measuring nothing.
        let (filled, changed) = MemoryMerge.merged(
            existing: control,
            candidate: AuthoredPush.proposal(for: control.title),
            now: TestClock.days(1)
        )
        #expect(filled.detail == AuthoredPush.proposedDetail, "the merge never offered a detail")
        #expect(filled.dueAt == AuthoredPush.proposedDueAt, "the merge never offered a due date")
        #expect(changed)
    }

    @Test("CF-54 near certainty does not buy an inferred candidate anything")
    func confidenceDoesNotOutrankAuthorship() {
        let authored = AuthoredPush.commitment(confidence: 0.3)

        for confidence in [0.5, 0.8, 0.95, 0.99] {
            let (merged, _) = MemoryMerge.merged(
                existing: authored,
                candidate: AuthoredPush.inferredRival(confidence: confidence),
                now: TestClock.days(2)
            )
            #expect(merged.title == AuthoredPush.sentence, "confidence \(confidence) bought a title rewrite")
            #expect(merged.detail == AuthoredPush.authoredDetail, "confidence \(confidence) bought a detail rewrite")
            #expect(merged.dueAt == AuthoredPush.authoredDueAt, "confidence \(confidence) moved the due date")
            #expect(merged.source == .authored)
            #expect(merged.confidence > authored.confidence, "confidence \(confidence) was not taken as corroboration")
        }
    }

    @Test("CF-54 the merge is stable however many times it is repeated")
    func repeatedMergesAreIdempotent() {
        let authored = AuthoredPush.commitment()
        var current = authored

        for pass in 1...8 {
            let (merged, _) = MemoryMerge.merged(
                existing: current,
                candidate: AuthoredPush.inferredRival(),
                now: TestClock.days(Double(pass))
            )
            #expect(merged.title == authored.title, "pass \(pass) rewrote the title")
            #expect(merged.detail == authored.detail, "pass \(pass) rewrote the detail")
            #expect(merged.dueAt == authored.dueAt, "pass \(pass) moved the due date")
            #expect(merged.source == .authored, "pass \(pass) demoted the source")
            #expect(merged.confidence >= current.confidence, "pass \(pass) lowered confidence")
            current = merged
        }

        // Confidence is the only field that ever moved, and it stops at the ceiling rather
        // than creeping toward certainty forever.
        #expect(current.confidence <= 0.99)
        let (saturated, changed) = MemoryMerge.merged(
            existing: current,
            candidate: AuthoredPush.inferredRival(),
            now: TestClock.days(9)
        )
        #expect(!changed, "a merge that moves nothing must report no change, or the store is rewritten for free")
        #expect(saturated == current, "a saturated merge must be a no-op down to the last field")
    }

    @Test("CF-54 an authored candidate replaces the guess it collides with, in the other order")
    func authoredCandidateWinsAgainstStoredInferred() {
        // The reverse of every other case here: Memoir guessed first and the user has now said
        // the same thing out loud. Their wording is the one worth keeping, so the stored
        // spelling is deliberately the scruffy one the screen happened to show.
        let stored = AuthoredPush.inferredRival(
            confidence: 0.9,
            title: "send the signed lease scan to elena by friday!!"
        )
        let authored = AuthoredPush.commitment(confidence: 0.4)
        #expect(stored.title != authored.title, "identical strings would make the title assertion below free")
        #expect(
            MemoryText.dedupeKey(kind: .commitment, title: stored.title)
                == MemoryText.dedupeKey(kind: .commitment, title: authored.title),
            "the two spellings must normalise identically or these rows would never meet"
        )

        let (merged, changed) = MemoryMerge.merged(
            existing: stored,
            candidate: authored,
            now: TestClock.days(2)
        )

        #expect(changed)
        #expect(merged.id == stored.id, "the surviving row is still the one the store already had")
        #expect(merged.title == AuthoredPush.sentence, "the row kept a guess's wording over the user's own")
        #expect(merged.detail == AuthoredPush.authoredDetail, "the user's detail lost to a guessed one")
        #expect(merged.dueAt == AuthoredPush.authoredDueAt, "the user's due date lost to a guessed one")
        #expect(merged.source == .authored, "the row is the user's words now and must say so")

        // Silence is not an instruction. A push with no date does not clear one that is
        // already there; only a direct edit empties a field.
        var dateless = authored
        dateless.dueAt = nil
        dateless.detail = nil
        let (kept, _) = MemoryMerge.merged(existing: stored, candidate: dateless, now: TestClock.days(3))
        #expect(kept.dueAt == stored.dueAt)
        #expect(kept.detail == stored.detail)
        #expect(kept.source == .authored)
    }

    @Test("CF-54 source climbs to authored and never decays back")
    func sourceNeverDecays() {
        let authored = AuthoredPush.commitment()

        // Down is impossible.
        let (held, _) = MemoryMerge.merged(
            existing: authored,
            candidate: AuthoredPush.inferredRival(),
            now: TestClock.days(1)
        )
        #expect(held.source == .authored)

        // Up happens on contact, before any other rule gets a say, including on a row the
        // user had already corrected. The fields stay frozen there, but the row is the user's
        // work either way and the list has to be able to say so.
        var corrected = AuthoredPush.inferredRival(confidence: 0.5)
        corrected.corrected = true
        corrected.title = "Scan the lease and send it to Elena"
        let (promoted, changed) = MemoryMerge.merged(
            existing: corrected,
            candidate: AuthoredPush.commitment(),
            now: TestClock.days(1)
        )
        #expect(promoted.source == .authored)
        #expect(changed)
        #expect(promoted.title == corrected.title, "a correction is the user's judgement about this exact row")

        #expect(EntitySource.authored.outranks(.inferred))
        #expect(!EntitySource.inferred.outranks(.authored))
        #expect(!EntitySource.authored.outranks(.authored), "authorship is not a licence to overwrite other authorship")
    }

    // MARK: The law, through a real consolidation pass

    @Test("CF-54 an authored commitment survives five consecutive, progressively more confident passes")
    func authoredSurvivesRepeatedConsolidation() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            let capture = AuthoredPush.capture()
            let authored = AuthoredPush.commitment()
            try await seed(store: store, captures: [capture], entities: [authored])

            // The collision is the premise of the test, so it is asserted rather than assumed.
            let proposal = try #require(
                try await RuleExtractor().extract(from: [capture]).entities
                    .first { $0.kind == .commitment },
                "the note must yield a commitment or no merge is being exercised"
            )
            #expect(
                MemoryText.dedupeKey(kind: proposal.kind, title: proposal.title)
                    == MemoryText.dedupeKey(kind: authored.kind, title: authored.title),
                "extraction proposed \"\(proposal.title)\", which does not dedupe onto the authored row"
            )
            #expect(proposal.dueAt != authored.dueAt, "the guessed due date matches the user's by accident")
            #expect(proposal.detail != authored.detail, "the guessed detail matches the user's by accident")

            let countBefore = try await store.entities(kind: nil, includeDeleted: true).count
            var previousConfidence = authored.confidence

            for pass in 1...5 {
                let overconfident = OverconfidentExtractor(
                    base: RuleExtractor(),
                    confidence: 0.6 + Double(pass) * 0.07,
                    detail: "Rewritten by extraction pass \(pass)",
                    dueAt: TestClock.days(Double(40 + pass))
                )
                let service = MemoryService(store: store, extractors: [overconfident])
                _ = try await service.consolidate(
                    since: TestClock.hours(-1),
                    now: TestClock.days(Double(pass))
                )

                let after = try #require(try await store.entity(id: authored.id))
                #expect(after.title == AuthoredPush.sentence, "pass \(pass) rewrote the title as \"\(after.title)\"")
                #expect(after.detail == AuthoredPush.authoredDetail, "pass \(pass) rewrote the detail")
                #expect(
                    after.dueAt == AuthoredPush.authoredDueAt,
                    "pass \(pass) moved the due date to \(after.dueAt.map(TestClock.iso) ?? "nil")"
                )
                #expect(after.source == .authored, "pass \(pass) demoted the source to \(after.source.rawValue)")
                #expect(after.kind == .commitment, "pass \(pass) changed the kind")
                #expect(!after.deleted, "pass \(pass) deleted the entity")
                #expect(!after.corrected, "an authored row was never corrected and must not claim to be")
                #expect(
                    after.confidence >= previousConfidence,
                    "pass \(pass) lowered confidence from \(previousConfidence) to \(after.confidence)"
                )
                previousConfidence = after.confidence

                // The other way to lose the user's words: leave the row alone and file the
                // guess beside it.
                let all = try await store.entities(kind: nil, includeDeleted: true)
                #expect(all.count == countBefore, "pass \(pass) added \(all.count - countBefore) entities")
                #expect(
                    all.filter { $0.kind == .commitment }.count == 1,
                    "pass \(pass) forked the commitment into \(all.filter { $0.kind == .commitment }.map(\.title))"
                )
            }

            #expect(
                previousConfidence > authored.confidence,
                "five corroborating passes must still be allowed to raise confidence"
            )
            assertNoNetwork()
        }
    }

    @Test("CF-54 five passes cannot supply a due date the user never gave")
    func bareAuthoredFieldsSurviveConsolidation() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            let capture = AuthoredPush.bareCapture()
            let authored = AuthoredPush.bare(title: AuthoredPush.bareTitles.authored, source: .authored)
            let control = AuthoredPush.bare(title: AuthoredPush.bareTitles.control, source: .inferred)
            try await seed(store: store, captures: [capture], entities: [authored, control])

            var previousConfidence = authored.confidence

            for pass in 1...5 {
                let proposing = ProposingExtractor(
                    titles: [authored.title, control.title],
                    detail: "Supplied by extraction pass \(pass)",
                    dueAt: TestClock.days(Double(40 + pass)),
                    confidence: 0.6 + Double(pass) * 0.07
                )
                let service = MemoryService(store: store, extractors: [proposing])
                _ = try await service.consolidate(
                    since: TestClock.hours(-1),
                    now: TestClock.days(Double(pass))
                )

                let after = try #require(try await store.entity(id: authored.id))
                #expect(after.title == authored.title, "pass \(pass) rewrote the title")
                #expect(after.detail == nil, "pass \(pass) filled a detail the user left blank")
                #expect(
                    after.dueAt == nil,
                    "pass \(pass) invented a due date of \(after.dueAt.map(TestClock.iso) ?? "nil")"
                )
                #expect(after.source == .authored, "pass \(pass) demoted the source")
                #expect(after.confidence >= previousConfidence, "pass \(pass) lowered confidence")
                previousConfidence = after.confidence

                #expect(
                    try await store.entities(kind: nil, includeDeleted: true).count == 2,
                    "pass \(pass) forked one of the two commitments"
                )
            }

            #expect(previousConfidence > authored.confidence, "corroboration must still raise confidence")

            // The control, in the same store, met by the same five passes.
            let filled = try #require(try await store.entity(id: control.id))
            #expect(
                filled.detail?.hasPrefix("Supplied by extraction pass") == true,
                "the passes never offered a detail, so nothing above was resisted"
            )
            #expect(filled.dueAt != nil, "the passes never offered a due date, so nothing above was resisted")
            #expect(filled.source == .inferred)
            assertNoNetwork()
        }
    }

    @Test("CF-54 an extraction result carrying the authored row's own id cannot rewrite it")
    func authoredSurvivesAnIdCollision() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            let authored = AuthoredPush.commitment()
            try await seed(store: store, entities: [authored])

            // The nastiest shape there is: extraction resolving onto the exact row and asking
            // for a different title at maximum confidence, with a pin thrown in.
            let hostile = Entity(
                id: authored.id,
                kind: .commitment,
                title: "Email Elena about the lease, per the extractor",
                detail: "Model rewrite",
                dueAt: TestClock.days(99),
                confidence: 0.99,
                pinned: true,
                corrected: false,
                deleted: false,
                source: .inferred,
                createdAt: TestClock.reference,
                updatedAt: TestClock.days(3)
            )
            let service = MemoryService(store: store, extractors: [])
            _ = try await service.commit(
                ExtractionResult(entities: [hostile], provenance: []),
                now: TestClock.days(3)
            )

            let after = try #require(try await store.entity(id: authored.id))
            #expect(after.title == AuthoredPush.sentence)
            #expect(after.detail == AuthoredPush.authoredDetail)
            #expect(after.dueAt == AuthoredPush.authoredDueAt)
            #expect(after.source == .authored)
            #expect(!after.pinned, "extraction must not be able to pin an entity either")
            #expect(try await store.entities(kind: nil, includeDeleted: true).count == 1)
        }
    }

    // MARK: CF-55 · The flag is visible, and it survives the trip to disk

    @Test("CF-55 a mixed list reports what each row is, before and after consolidation")
    func sourceSurvivesTheRoundTrip() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            let capture = AuthoredPush.capture()
            let authored = AuthoredPush.commitment()
            let guessed = Entity(
                id: TestID.stable("inferred", "deposit"),
                kind: .note,
                title: "Deposit is with the previous agency",
                confidence: 0.5,
                source: .inferred,
                createdAt: TestClock.reference,
                updatedAt: TestClock.reference
            )
            try await seed(store: store, captures: [capture], entities: [authored, guessed])

            func sources() async throws -> [ID: EntitySource] {
                let rows = try await store.entities(kind: nil, includeDeleted: false)
                return Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0.source) })
            }

            let onRead = try await sources()
            #expect(onRead[authored.id] == .authored, "the authored row came back as a guess")
            #expect(onRead[guessed.id] == .inferred, "a guess came back claiming the user wrote it")

            let service = MemoryService(store: store, extractors: [RuleExtractor()])
            _ = try await service.consolidate(since: TestClock.hours(-1), now: TestClock.days(1))

            let afterConsolidation = try await sources()
            #expect(afterConsolidation[authored.id] == .authored, "consolidation relabelled the user's own row")
            #expect(afterConsolidation[guessed.id] == .inferred)
            // Every row extraction added is a guess and must say so.
            #expect(
                afterConsolidation.filter { $0.value == .authored }.count == 1,
                "consolidation minted a row claiming to be authored"
            )

            // The store is the last line: a writer that simply forgets the flag must not be
            // able to demote the row, because in-memory policy cannot protect a raw upsert.
            var demoted = authored
            demoted.source = .inferred
            demoted.updatedAt = TestClock.days(2)
            try await store.upsert(entity: demoted)
            let reread = try #require(try await store.entity(id: authored.id))
            #expect(reread.source == .authored, "a plain upsert demoted the user's words to a guess")
        }
    }

    // MARK: CF-56 · Completing is permanent

    @Test("CF-56 a completed authored commitment is never resurrected by a later pass")
    func completedAuthoredStaysDone() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            let capture = AuthoredPush.capture()
            let authored = AuthoredPush.commitment()
            try await seed(store: store, captures: [capture], entities: [authored])

            // Done is a soft delete: the row and its provenance stay, it just stops counting.
            try await store.deleteEntity(id: authored.id)
            #expect(try #require(try await store.entity(id: authored.id)).deleted)
            let countBefore = try await store.entities(kind: nil, includeDeleted: true).count

            for pass in 1...3 {
                let overconfident = OverconfidentExtractor(
                    base: RuleExtractor(),
                    confidence: 0.8 + Double(pass) * 0.05,
                    detail: "Re-observed on pass \(pass)",
                    dueAt: TestClock.days(Double(50 + pass))
                )
                let service = MemoryService(store: store, extractors: [overconfident])
                _ = try await service.consolidate(
                    since: TestClock.hours(-1),
                    now: TestClock.days(Double(10 + pass))
                )

                let after = try #require(try await store.entity(id: authored.id))
                #expect(after.deleted, "pass \(pass) resurrected a commitment the user had finished with")
                #expect(after.source == .authored, "pass \(pass) demoted a completed authored row")
                #expect(after.title == AuthoredPush.sentence, "pass \(pass) rewrote a completed row's title")

                let live = try await store.entities(kind: nil, includeDeleted: false)
                #expect(!live.contains { $0.id == authored.id }, "pass \(pass) made it visible again")
                let doneKey = MemoryText.dedupeKey(kind: .commitment, title: AuthoredPush.sentence)
                #expect(
                    !live.contains { MemoryText.dedupeKey(kind: $0.kind, title: $0.title) == doneKey },
                    "pass \(pass) re-created it under a second id, which is resurrection with extra steps"
                )
                #expect(
                    try await store.entities(kind: nil, includeDeleted: true).count == countBefore,
                    "pass \(pass) added rows"
                )
            }
        }
    }

    @Test("CF-56 the merge itself has no way to clear the deleted flag")
    func mergeCannotUndelete() {
        // The store-level guard above is one line in `MemoryService`. This is the other half:
        // even called directly, with the most alive-looking candidate available, the merge
        // starts from `existing` and never assigns `deleted`.
        let done = AuthoredPush.commitment(confidence: 0.4, deleted: true)

        let (merged, _) = MemoryMerge.merged(
            existing: done,
            candidate: AuthoredPush.inferredRival(confidence: 0.99),
            now: TestClock.days(4)
        )
        #expect(merged.deleted)
        #expect(merged.source == .authored)
        #expect(merged.title == AuthoredPush.sentence)

        // Not even a second authored version of the same sentence brings it back. Re-adding a
        // finished commitment is a new decision, and the push path has to make it explicitly.
        var again = AuthoredPush.commitment(at: TestClock.days(5))
        again.detail = "Agent asked for it again"
        let (rePushed, _) = MemoryMerge.merged(existing: done, candidate: again, now: TestClock.days(5))
        #expect(rePushed.deleted)
    }
}
