//
//  SemanticPerfTests.swift
//  The passage vectors are stored, and storing them changed nothing about the answers.
//
//  Semantic search used to re-embed every passage of every shortlisted capture on every
//  single search: up to 12 passages per capture at ~4ms each, for 72 candidates. Measured on
//  the real 482-vector corpus in a release build, "what was that repo about screen memory"
//  spent 3665ms there and "the tweet about claude skills wrapped in an sms app" 7849ms, out
//  of a 24s answer. Schema v4 stores those vectors; the same two searches now take 6ms and
//  9ms and return the identical twelve captures, scored identically to six decimal places.
//
//  These tests defend both halves of that sentence (the speed and the sameness) without
//  ever reading the wall clock, which would make them a stopwatch on a busy CI box rather
//  than a test. Speed is asserted as WORK NOT DONE: `SemanticIndex.passageCacheMisses`
//  counts the captures a search had to embed for itself, and over a backfilled corpus that
//  number must stay at zero. Sameness is asserted by ranking the same corpus twice, once
//  with the vectors computed on the fly and once with them read back from SQLite.
//

import Foundation
import Testing

import MemoirFixtures
@testable import MemoirKit

@Suite("Semantic search reads its passage vectors instead of recomputing them")
struct SemanticPerfTests {

    /// A question phrased the way a person half-remembers something, so the answer has to
    /// come from meaning rather than from matching words.
    static let question = "that project that watches my screen and remembers things for me"

    // MARK: - Corpus

    /// Long, mixed pages (navigation chrome, unrelated paragraphs, one paragraph that
    /// matters), because that is the shape passages exist to handle. A capture below 40
    /// characters would be a single passage and would prove nothing.
    static func corpus() -> [CaptureEvent] {
        var out: [CaptureEvent] = []
        for (offset, page) in pages.enumerated() {
            out.append(
                Fixtures.capture(
                    text: page.text,
                    app: "Safari",
                    bundleID: "com.apple.Safari",
                    windowTitle: page.title,
                    at: TestClock.hours(Double(-offset)),
                    name: "semanticPerf-\(page.title)"
                )
            )
        }
        return out
    }

    /// Seeds the corpus and gives every capture a whole-capture vector, and NO passage
    /// vectors: exactly the state of a database written before schema v4.
    ///
    /// - Returns: false when this machine has no sentence embeddings, so the caller can
    ///   skip rather than assert something it cannot compute.
    @discardableResult
    static func seedAsBeforeV4(_ store: Store) async throws -> Bool {
        guard SemanticIndex.embed("a sentence long enough to embed properly") != nil else {
            return false
        }
        for capture in corpus() {
            try await store.insert(capture: capture)
            guard let vector = SemanticIndex.embed(capture.text) else { continue }
            try await store.setEmbedding(captureID: capture.id, vector: vector)
        }
        return true
    }

    static func ids(_ hits: [(id: ID, score: Double)]) -> [ID] { hits.map(\.id) }

    // MARK: - Tests

    @Test("a search over a backfilled corpus embeds no passages at all, twice over")
    func backfilledCorpusNeverReEmbeds() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            guard try await Self.seedAsBeforeV4(store) else { return }

            let index = SemanticIndex(store: store)
            let drained = try await index.backfillPassages()
            #expect(drained == Self.pages.count, "every embeddable capture should be drained")

            let first = try await index.search(Self.question)
            #expect(!first.isEmpty, "the corpus is meant to contain matches")
            #expect(
                await index.passageCacheMisses == 0,
                "a backfilled corpus must be scored entirely from stored vectors")

            let second = try await index.search(Self.question)
            #expect(
                await index.passageCacheMisses == 0,
                "a second identical search must not re-embed anything")
            #expect(Self.ids(first) == Self.ids(second))
        }
    }

    @Test("the same ranking, whether the vectors were computed or read back")
    func rankingIsUnchangedByCaching() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            guard try await Self.seedAsBeforeV4(store) else { return }

            // First search: nothing stored, so every shortlisted capture is embedded here.
            let index = SemanticIndex(store: store)
            let computed = try await index.search(Self.question)
            let misses = await index.passageCacheMisses
            #expect(misses > 0, "with no stored vectors the search must have done the work")
            #expect(!computed.isEmpty)

            // Second search: the same shortlist, now read out of SQLite.
            let cached = try await index.search(Self.question)
            #expect(
                await index.passageCacheMisses == misses,
                "the work done on the way through must have been remembered")

            #expect(Self.ids(computed) == Self.ids(cached), "the order must not move")
            for (a, b) in zip(computed, cached) {
                #expect(
                    abs(a.score - b.score) < 1e-9,
                    "\(a.id) scored \(a.score) computed and \(b.score) cached")
            }
        }
    }

    @Test("a fresh index over the same database inherits the stored vectors")
    func storedVectorsSurviveTheIndex() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            guard try await Self.seedAsBeforeV4(store) else { return }

            let warm = SemanticIndex(store: store)
            let before = try await warm.search(Self.question)
            #expect(await warm.passageCacheMisses > 0)

            // The vectors live in the database, not in the actor, so a relaunch keeps them.
            let cold = SemanticIndex(store: store)
            let after = try await cold.search(Self.question)
            #expect(
                await cold.passageCacheMisses == 0,
                "a new index over a filled database must not re-embed a thing")
            #expect(Self.ids(before) == Self.ids(after))
        }
    }

    @Test("backfilling passages is idempotent and leaves nothing behind")
    func backfillDrainsExactlyOnce() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            guard try await Self.seedAsBeforeV4(store) else { return }

            let index = SemanticIndex(store: store)
            let first = try await index.backfillPassages()
            #expect(first == Self.pages.count)
            let second = try await index.backfillPassages()
            #expect(second == 0, "a second pass must find nothing to do")

            let stored = try await store.passageVectors(for: Self.corpus().map(\.id))
            #expect(stored.count == Self.pages.count)
            for (id, vectors) in stored {
                #expect(!vectors.isEmpty, "\(id) stored no passages at all")
                #expect(vectors.allSatisfy { $0.count == vectors[0].count })
            }
        }
    }

    @Test("a read-only store searches correctly and writes nothing back")
    func readOnlyStoreStillSearches() async throws {
        try await TestWorkspace.with { ws in
            let writable = try await ws.store()
            guard try await Self.seedAsBeforeV4(writable) else { return }
            await writable.close()

            // The MCP server opens the database like this. It has to answer, and it must not
            // try to fill the cache on the way.
            let readOnly = try await ws.readOnlyStore()
            let index = SemanticIndex(store: readOnly)
            let hits = try await index.search(Self.question)
            #expect(!hits.isEmpty)
            #expect(await index.passageCacheMisses > 0, "nothing was stored for it to read")
            await readOnly.close()

            let reopened = try await ws.store()
            let stored = try await reopened.passageVectors(for: Self.corpus().map(\.id))
            #expect(stored.isEmpty, "a read-only search must not have written vectors")

            // And it is the same answer a writable store gives, so nobody is served a worse
            // memory for having opened it read-only.
            let writableHits = try await SemanticIndex(store: reopened).search(Self.question)
            #expect(Self.ids(writableHits) == Self.ids(hits))
        }
    }

    @Test("passages still beat whole-capture scoring, which is why they are stored at all")
    func passagesOutrankTheWholeCaptureVector() async throws {
        guard let query = SemanticIndex.embed(Self.question) else { return }
        guard let target = Self.pages.first(where: { $0.title == "Afterglance" }),
              let distractor = Self.pages.first(where: { $0.title == "Redis" })
        else { return }

        // The whole-capture vector of the right page is dragged down by everything else on
        // it. This is the measurement that put passages in the code: on the real corpus the
        // correct capture scored 0.306 as a whole, below unrelated pages at 0.44.
        guard let wholeTarget = SemanticIndex.embed(target.text),
              let wholeDistractor = SemanticIndex.embed(distractor.text)
        else { return }
        let coarseTarget = SemanticIndex.cosine(query, wholeTarget)
        let coarseDistractor = SemanticIndex.cosine(query, wholeDistractor)

        let passageTarget = SemanticIndex.bestPassageScore(
            SemanticIndex.passageVectors(target.text), query: query)
        let passageDistractor = SemanticIndex.bestPassageScore(
            SemanticIndex.passageVectors(distractor.text), query: query)

        #expect(
            passageTarget > coarseTarget,
            "the best passage must beat the averaged page, or passages buy nothing")
        #expect(
            passageTarget > passageDistractor,
            "passage scoring must still separate the right page from the wrong one")
        #expect(coarseDistractor > 0, "sanity: the distractor embeds")
    }

    @Test("the shortlist stays six candidates per result")
    func shortlistWidthIsSixPerResult() async throws {
        // Width is measured, not assumed: on the real corpus a 72-candidate shortlist costs
        // 5.6ms against 5.3ms for six, because what a search spends its time on is embedding
        // the question, not re-scoring candidates. Narrowing it would save nothing and could
        // only lose recall, so this pins the width in place.
        //
        // A separate workspace per width, because a search fills the cache as it goes and the
        // count being asserted is exactly what was NOT yet cached.
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            guard try await Self.seedAsBeforeV4(store) else { return }
            let index = SemanticIndex(store: store)
            _ = try await index.search(Self.question, limit: 12)
            #expect(
                await index.passageCacheMisses == Self.pages.count,
                "limit 12 must consider 72 candidates, which is the whole corpus here")
        }

        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            guard try await Self.seedAsBeforeV4(store) else { return }
            let narrow = SemanticIndex(store: store)
            _ = try await narrow.search(Self.question, limit: 1)
            #expect(
                await narrow.passageCacheMisses == 6,
                "limit 1 must consider exactly six")
        }
    }

    // MARK: - Pages
    //
    // Written out rather than generated: the ranking assertions are only meaningful if the
    // text is the kind of thing a person actually reads on a screen.

    struct Page: Sendable {
        let title: String
        let text: String
    }

    static let chrome = """
        Skip to content. Product Solutions Resources Open Source Enterprise Pricing Sign in \
        Sign up. Notifications Fork Star Watch. Issues Pull requests Actions Projects Wiki \
        Security Insights Settings. Terms Privacy Docs Contact Manage cookies Do not share my \
        personal information.
        """

    static let pages: [Page] = [
        Page(
            title: "Afterglance",
            text: """
                \(chrome) README.md. Afterglance quietly records what appears on your display \
                and lets you ask about it later in plain language, so the thing you glanced at \
                on Tuesday is still reachable on Friday. Everything is kept on the machine \
                itself and nothing is uploaded anywhere. \(chrome) Installation requires a \
                recent toolchain and about four hundred megabytes of disk. Contributions are \
                welcome, please read the contributing guide first. Released under the MIT \
                licence. \(chrome)
                """),
        Page(
            title: "Redis",
            text: """
                \(chrome) Redis is an in-memory data structure store used as a database, cache, \
                message broker and streaming engine. It supports strings, hashes, lists, sets, \
                sorted sets with range queries, bitmaps, hyperloglogs and geospatial indexes. \
                Redis has built-in replication, Lua scripting, least recently used eviction, \
                transactions and different levels of on-disk persistence. \(chrome) Memory \
                usage can be tuned with maxmemory policies. Documentation, community and \
                commercial support are available. \(chrome)
                """),
        Page(
            title: "Kubernetes",
            text: """
                \(chrome) Kubernetes automates deployment, scaling and management of \
                containerised applications across a cluster of machines. A deployment declares \
                the desired state and the control plane reconciles the cluster towards it, \
                restarting containers that fail and rescheduling them when a node goes away. \
                \(chrome) Services give pods a stable address. Ingress routes external traffic. \
                Persistent volumes outlive the pods that mount them. \(chrome)
                """),
        Page(
            title: "Espresso",
            text: """
                \(chrome) Pulling a good espresso is mostly about grind size, dose and time. \
                Aim for eighteen grams in and thirty-six grams out in about twenty-eight \
                seconds, then adjust the grinder rather than the dose when the shot runs fast \
                or chokes. \(chrome) Water temperature matters less than people think; \
                consistency matters more. Clean the group head daily and the basket after every \
                session. \(chrome)
                """),
        Page(
            title: "Sleep",
            text: """
                \(chrome) Sleep consolidates memory. During slow wave sleep the hippocampus \
                replays the day's experiences to the cortex, which is where they are stored for \
                the long term, and cutting the night short cuts that replay short too. \(chrome) \
                Light in the evening delays the circadian phase. Caffeine has a half life of \
                around five hours, so an afternoon cup is still working at bedtime. \(chrome)
                """),
        Page(
            title: "Rust ownership",
            text: """
                \(chrome) Ownership is how Rust manages memory without a garbage collector. \
                Each value has exactly one owner, the value is dropped when the owner goes out \
                of scope, and borrowing lets other code read or mutate it for a bounded \
                lifetime. \(chrome) The borrow checker rejects a program that could observe a \
                dangling reference. Lifetimes are usually inferred and only written down when \
                the compiler cannot work them out. \(chrome)
                """),
        Page(
            title: "Bicycle maintenance",
            text: """
                \(chrome) A drivetrain lasts far longer when it is clean. Degrease the chain, \
                dry it, then apply one drop of lubricant per roller and wipe the excess off, \
                because the oil left on the outside only collects grit. \(chrome) Check the \
                chain for wear with a gauge every few hundred kilometres; replacing a worn \
                chain early saves the cassette and the chainrings. \(chrome)
                """),
        Page(
            title: "Sourdough",
            text: """
                \(chrome) A starter is a culture of wild yeast and lactic acid bacteria kept \
                alive by regular feeding with flour and water. A loaf rises on that culture \
                alone, which is slower than commercial yeast and is what gives the bread its \
                flavour and keeping quality. \(chrome) Bulk fermentation is finished by feel \
                and volume rather than by the clock, since dough temperature decides the pace. \
                \(chrome)
                """),
        Page(
            title: "Postgres indexes",
            text: """
                \(chrome) A B-tree index answers equality and range queries on ordered data and \
                is what you get by default. GIN suits documents and arrays where one row holds \
                many keys, and BRIN suits enormous tables whose physical order tracks the \
                column. \(chrome) An index that is never used still costs time on every write, \
                so drop the ones the planner ignores. Run analyse after a bulk load. \(chrome)
                """),
        Page(
            title: "Photography",
            text: """
                \(chrome) Exposure is three settings in tension. Aperture decides how much of \
                the scene is sharp, shutter speed decides whether movement blurs, and \
                sensitivity decides how much noise you accept for the other two. \(chrome) \
                Shooting raw keeps the latitude to recover a bright sky later. Light in the \
                hour after sunrise is soft and directional and flatters almost anything. \
                \(chrome)
                """),
        Page(
            title: "Regex",
            text: """
                \(chrome) A regular expression describes a set of strings. Anchors tie a match \
                to a boundary, character classes stand for a set of characters, and quantifiers \
                say how many times the preceding element may repeat. \(chrome) Greedy \
                quantifiers take as much as they can and give back only when the rest of the \
                pattern fails, which is where catastrophic backtracking comes from. \(chrome)
                """),
        Page(
            title: "Tea",
            text: """
                \(chrome) Green tea is steamed or pan fired soon after picking, which stops \
                oxidation and keeps the leaf green. Black tea is rolled and left to oxidise \
                fully. Oolong sits between the two and covers an enormous range of styles. \
                \(chrome) Water just off the boil suits black tea; green tea prefers something \
                cooler or it turns bitter. \(chrome)
                """),
    ]
}
