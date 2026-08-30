//
//  EntityLinkingTests.swift
//  Retrieval that follows names rather than words, and ranking that knows how old a
//  belief is.
//
//  Two claims are under test:
//
//  1. A question that names a project by one of its aliases reaches the captures that use
//     a different one. Neither keyword search nor cosine similarity can do this; only the
//     ontology holds both ends of a rename.
//  2. A stale inferred entity is outranked by a fresh one, and nothing the user wrote is
//     ever demoted by age, whatever the curve says.
//

import Foundation
import Testing

import MemoirFixtures
@testable import MemoirKit

// MARK: - Alias-aware lookup

@Suite("Entity linking: alias lookup")
struct EntityAliasLookupTests {

    @Test("An alias finds its entity, though no full-text index contains it")
    func aliasFindsEntity() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            // The alias deliberately shares nothing with the title. A ticket prefix is the
            // usual case and the usual shape: the thing is called one name by people and a
            // different one by every system that tracks it.
            let fenwick = makeEntity(
                kind: .project,
                title: "Fenwick Migration",
                source: .authored,
                aliases: ["PLAT", "cutover-2026"]
            )
            try await store.upsert(entity: fenwick)

            // The control: this is what the full-text index can already do.
            let byTitle = try await store.searchEntities("Fenwick", limit: 5)
            #expect(byTitle.contains { $0.id == fenwick.id })

            // The claim: the alias lives in a JSON column no FTS trigger feeds, so the index
            // cannot reach it, and unlike "FEN", "PLAT" is not a prefix of the title either,
            // so the tokeniser cannot accidentally rescue it.
            let byFTS = try await store.searchEntities("PLAT", limit: 5)
            #expect(!byFTS.contains { $0.id == fenwick.id },
                    "if FTS starts indexing aliases this test is obsolete, not failing")

            let byAlias = try await store.entitiesNamed("PLAT", limit: 5)
            #expect(byAlias.map(\.id) == [fenwick.id])
        }
    }

    @Test("Alias matching is case-insensitive and exact, never a substring")
    func aliasMatchingIsExact() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            let fenwick = makeEntity(
                kind: .project, title: "Fenwick Migration", aliases: ["FEN"])
            try await store.upsert(entity: fenwick)

            #expect(try await store.entitiesNamed("fen", limit: 5).count == 1)
            #expect(try await store.entitiesNamed("FEN", limit: 5).count == 1)

            // "fe" is a prefix of the alias and "fenwick" contains it. A substring match on
            // a three-letter token would claim half the memory, which is the whole reason
            // this lookup compares against the quoted JSON form.
            #expect(try await store.entitiesNamed("fe", limit: 5).isEmpty)
            #expect(try await store.entitiesNamed("enw", limit: 5).isEmpty)
        }
    }

    @Test("A deleted entity is never returned by name")
    func deletedIsHidden() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            try await store.upsert(entity: makeEntity(
                kind: .project, title: "Retired Thing", deleted: true, aliases: ["RET"]))
            #expect(try await store.entitiesNamed("RET", limit: 5).isEmpty)
        }
    }

    @Test("Authored entities lead when two things share a name")
    func authoredLeads() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            let guessed = makeEntity(
                id: TestID.stable("guessed"), kind: .project, title: "Atlas",
                source: .inferred)
            let written = makeEntity(
                id: TestID.stable("written"), kind: .project, title: "Atlas",
                source: .authored)
            try await store.upsert(entity: guessed)
            try await store.upsert(entity: written)

            let hits = try await store.entitiesNamed("atlas", limit: 5)
            #expect(hits.first?.id == written.id)
        }
    }
}

// MARK: - Name expansion

@Suite("Entity linking: name expansion")
struct LinkedNamesTests {

    @Test("Names already in the question are dropped, aliases are kept")
    func dropsNamesTheQuestionUsed() {
        let fenwick = makeEntity(
            kind: .project, title: "Fenwick Migration", aliases: ["FEN", "fenwick-mig"])
        let names = MemoryRank.linkedNames(
            for: [fenwick], question: "how is the fenwick migration going")

        // The asker already said this, so keyword search has already searched for it.
        // Searching it again would put four copies of one signal into the fusion.
        #expect(!names.contains("Fenwick Migration"))
        // These are the names the asker did NOT say. They are the whole contribution.
        #expect(names.contains("FEN"))
        #expect(names.contains("fenwick-mig"))
    }

    @Test("Aliases come before titles")
    func aliasesFirst() {
        let entity = makeEntity(kind: .project, title: "Atlas", aliases: ["ATL"])
        let names = MemoryRank.linkedNames(for: [entity], question: "what happened recently")
        #expect(names.first == "ATL", "the alias is the name that got the entity missed")
    }

    @Test("Names shorter than three characters are never searched for")
    func dropsShortNames() {
        let entity = makeEntity(kind: .project, title: "Go", aliases: ["Q", "id"])
        #expect(MemoryRank.linkedNames(for: [entity], question: "status").isEmpty)
    }

    @Test("Deleted entities contribute nothing")
    func skipsDeleted() {
        let entity = makeEntity(
            kind: .project, title: "Retired", deleted: true, aliases: ["RET"])
        #expect(MemoryRank.linkedNames(for: [entity], question: "status").isEmpty)
    }
}

// MARK: - Temporal decay

@Suite("Entity linking: temporal decay")
struct RecencyWeightTests {

    private let now = TestClock.reference

    private func aged(_ days: Double, _ build: (Date) -> Entity) -> Entity {
        build(now.addingTimeInterval(-days * 86_400))
    }

    @Test("Fresh beats stale, and the curve stays inside its stated bounds")
    func curveShape() {
        let fresh = makeEntity(kind: .project, title: "Today", updatedAt: now)
        let fortnight = makeEntity(
            kind: .project, title: "Fortnight",
            updatedAt: now.addingTimeInterval(-14 * 86_400))
        let ancient = makeEntity(
            kind: .project, title: "Ancient",
            updatedAt: now.addingTimeInterval(-400 * 86_400))

        let f = MemoryRank.recencyWeight(for: fresh, now: now)
        let m = MemoryRank.recencyWeight(for: fortnight, now: now)
        let a = MemoryRank.recencyWeight(for: ancient, now: now)

        #expect(f > m && m > a, "the curve must be monotonic in age")
        #expect(f == MemoryRank.freshWeight)
        #expect(a == MemoryRank.staleWeight, "and it must floor rather than reach zero")
        // A fortnight is where boost turns into damping, roughly. Loose bounds on purpose:
        // this asserts the shape, not the constant.
        #expect(m > 0.8 && m < 1.2)
    }

    @Test("Nothing the user wrote ever goes stale")
    func authoredNeverDecays() {
        let old = now.addingTimeInterval(-400 * 86_400)
        for entity in [
            makeEntity(kind: .project, title: "Written", source: .authored, updatedAt: old),
            makeEntity(kind: .project, title: "Corrected", corrected: true, updatedAt: old),
            makeEntity(kind: .project, title: "Pinned", pinned: true, updatedAt: old),
        ] {
            #expect(MemoryRank.recencyWeight(for: entity, now: now) == MemoryRank.freshWeight,
                    "\(entity.title) was put there on purpose, and it is still there")
        }
    }

    @Test("A completed commitment drops to the floor the moment it is ticked")
    func completedCommitmentsFloor() {
        let done = makeEntity(
            kind: .commitment, title: "Ship the thing",
            completedAt: now, updatedAt: now)
        let open = makeEntity(kind: .commitment, title: "Ship the other thing", updatedAt: now)

        #expect(MemoryRank.recencyWeight(for: done, now: now) == MemoryRank.staleWeight)
        #expect(MemoryRank.recencyWeight(for: open, now: now) == MemoryRank.freshWeight)
    }

    @Test("A stale top hit loses to a fresh one below it")
    func recencyReorders() {
        let stale = makeEntity(
            id: TestID.stable("stale"), kind: .project, title: "Spring Thing",
            updatedAt: now.addingTimeInterval(-120 * 86_400))
        let fresh = makeEntity(
            id: TestID.stable("fresh"), kind: .project, title: "This Morning",
            updatedAt: now)

        // Search put the stale one first; recency is what corrects that.
        let ranked = MemoryRank.byRelevanceAndRecency([stale, fresh], now: now)
        #expect(ranked.map(\.id) == [fresh.id, stale.id])
    }

    @Test("A stale authored entity is not reordered below a fresh guess")
    func authoredSurvivesReordering() {
        let written = makeEntity(
            id: TestID.stable("written"), kind: .project, title: "My Project",
            source: .authored, updatedAt: now.addingTimeInterval(-200 * 86_400))
        let guessed = makeEntity(
            id: TestID.stable("guessed"), kind: .project, title: "Guessed", updatedAt: now)

        // Search ranked the authored one first and no amount of freshness may overturn
        // that. This is the assertion that caught the exemption sitting at a neutral 1.0,
        // where a boosted guess one rank down scored higher and took the lead.
        let ranked = MemoryRank.byRelevanceAndRecency([written, guessed], now: now)
        #expect(ranked.first?.id == written.id)

        // And it holds however far down the authored entity started, as long as it started
        // ahead: only a better search rank may beat authorship.
        let deep = MemoryRank.byRelevanceAndRecency(
            [written, guessed, guessed, guessed], now: now)
        #expect(deep.first?.id == written.id)
    }
}

// MARK: - End to end

@Suite("Entity linking: through the context packet")
struct EntityLinkedRetrievalTests {

    @Test("A question using one name reaches a capture that uses another")
    func aliasCrossesTheRename() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            let now = TestClock.reference

            // The user's own ontology, as a vault import would leave it: the project has a
            // human name and a ticket prefix, and the two never appear together.
            try await store.upsert(entity: makeEntity(
                kind: .project,
                title: "Fenwick Migration",
                source: .authored,
                aliases: ["PLAT"],
                at: now
            ))

            // The capture the question is about. It says "PLAT-42" and never says "fenwick",
            // and "PLAT" is not a prefix of "Fenwick", so no tokeniser trick connects the
            // two. The ontology is the only thing in the system holding both names.
            let target = Fixtures.capture(
                text: "PLAT-42 cutover checklist: drain the write queue, flip the read path, "
                    + "then retire the shim. Owner: me. Blocked on the staging snapshot.",
                app: "Linear",
                bundleID: "com.linear",
                windowTitle: "PLAT-42",
                // Five days back, and that is the point. Inside the recency window the
                // packet would carry this capture regardless of whether search found it,
                // and the test would pass while proving nothing. It did exactly that on
                // the first attempt. Out here, section 4 cannot rescue it: appearing in the
                // packet at all means the search path reached it.
                at: now.addingTimeInterval(-5 * 86_400),
                name: "plat-42-ticket"
            )
            // Distractors that DO contain the question's words, and that are recent, so a
            // keyword-only ranking has somewhere wrong to go and recency has something
            // legitimate to fill the packet with.
            let noise = (0..<6).map { i in
                Fixtures.capture(
                    text: "Migration guide chapter \(i): general notes on going about a "
                        + "migration, how a migration is going, and migration going forward.",
                    app: "Safari",
                    bundleID: "com.apple.Safari",
                    windowTitle: "Migration guide",
                    at: now.addingTimeInterval(-Double(i + 1) * 600),
                    name: "migration-noise-\(i)"
                )
            }
            for capture in noise + [target] { try await store.insert(capture: capture) }

            let service = MemoryService(store: store, extractors: [RuleExtractor()])
            let packet = try await service.context(
                for: "how is fenwick going", budget: 2_000, now: now, category: .recall)

            #expect(packet.captureIDs.contains(target.id),
                    "the ticket is the answer, and only the alias could find it")
        }
    }
}
