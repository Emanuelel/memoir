import Foundation
#if canImport(NaturalLanguage)
import NaturalLanguage
#endif

/// Semantic search over captures, so recall works on meaning rather than exact words.
///
/// Keyword search (FTS5) only matches literal text. Asked "what was that tweet about claude
/// skills wrapped in an sms app" it found nothing, because the post actually said "wrapped
/// **into** a nice sms app **layer**". A paraphrase of your own memory failed to reach it.
/// That defeats the point of asking a memory anything.
///
/// This embeds each capture once at write time and compares by cosine similarity, so
/// "wrapped in" and "wrapped into a … layer" land near each other. Same `NLEmbedding`
/// primitive the question router uses, measured at ~4ms per vector, fully on-device.
///
/// **Why brute force rather than a vector database.** Re-measured on a real database
/// (3,359 captures over 8 active days, 415 captures/day) with a benchmark of this file's own
/// ``cosine(_:_:)``:
///
///     corpus        scan time     resident (whole-capture vectors)
///     1.6k vectors      2 ms          3 MB
///      25k vectors     19 ms         49 MB
///     100k vectors     83 ms        195 MB      ← ``bruteForceCeiling``
///     250k vectors    180 ms        488 MB
///
/// The latency case for brute force holds: a vector index (sqlite-vec, FAISS, HNSW) would
/// save tens of milliseconds while adding a dependency to a project whose reliability comes
/// from having none.
///
/// **Disk has been wrong in this note twice, in both directions, so here is the measurement
/// and its date.** The first version counted only the 2 KB whole-capture vector and quoted
/// "60 days ≈ 47 MB", about 8x too low. The correction over-shot: it read the passage table at
/// its worst moment and quoted 25.6 KB per capture, which no longer holds.
///
/// Measured 22 Aug 2026 on a real database (12,490 captures, 131.5 MB total):
/// captures 65.9 MB, FTS 36.7 MB, passage vectors 15.9 MB, capture vectors 3.6 MB,
/// provenance 2.8 MB. That is **~10.7 KB per capture, roughly half of it index**. At the
/// measured ~400 captures/day: ~4 MB/day, ~125 MB/month, ~15 GB over a decade.
///
/// Two things to know before quoting it again. The text table is the largest one now, not
/// the passage vectors, so "the index costs more than the text" is no longer true. And the
/// row count includes imported history (contacts, calendar, photos), which is far cheaper per
/// row than a screen capture, so the average understates what a captured screen costs.
///
/// So the load-bearing sentence ("retention caps growth, so the corpus does not grow without
/// bound") is only true if retention actually runs, and only bounded at a size worth telling
/// the user about. Settings now shows the projection rather than leaving it in this comment.
///
/// Revisit when ``bruteForceCeiling`` is exceeded. Not close: the same database on 22 Aug 2026
/// held 1,627 capture vectors and 916 passage vectors against a ceiling of 100,000. Vectors are
/// embedded on demand rather than once per capture, which is why they trail the capture count
/// by so much. Do not project the ceiling from the capture rate.
///
/// **What actually made a search slow was never the scan.** It was re-embedding the passages
/// of every shortlisted capture, every time: 3665ms on 482 vectors, against 1ms for the scan
/// those figures above describe. Since schema v4 the passage vectors are stored alongside the
/// capture vectors (`capture_passage_vectors`), and the same search takes 6ms.
public actor SemanticIndex {
    /// Above this many vectors, brute force stops being the obvious choice.
    ///
    /// Set where a search would begin to be perceptible (~100ms). Below it, scanning every
    /// vector is simpler, exact, and dependency-free; above it, an approximate index is
    /// worth the complexity.
    public static let bruteForceCeiling = 100_000

    private let store: Store
    private var cache: [(id: ID, vector: [Float])] = []
    private var cacheLoadedAt: Date?

    /// How many captures this index has had to re-embed passage by passage during a search,
    /// because no stored vectors were available for them.
    ///
    /// Diagnostics, and the only honest way to assert in a test that the persisted vectors are
    /// actually being read: a timing assertion would be a wall-clock reading dressed up as a
    /// test. A search over a backfilled corpus leaves this untouched.
    private(set) var passageCacheMisses = 0

    public init(store: Store) {
        self.store = store
    }

    /// Embeds text, or nil when the language is unsupported or the text is unusable.
    ///
    /// Stored as `Float` rather than `Double`: the extra precision buys nothing for cosine
    /// ranking and doubles both the file and the memory held during a scan.
    public static func embed(_ text: String) -> [Float]? {
        #if canImport(NaturalLanguage)
        guard let embedding = NLEmbedding.sentenceEmbedding(for: .english) else { return nil }
        let trimmed = String(MemoryText.collapseWhitespace(text).prefix(600))
        guard trimmed.count >= 12 else { return nil }
        guard let v = embedding.vector(for: trimmed.lowercased()) else { return nil }
        return v.map(Float.init)
        #else
        return nil
        #endif
    }

    /// Splits a capture into passages small enough to embed meaningfully.
    ///
    /// `NLEmbedding` produces a SENTENCE embedding: hand it 2,300 characters of tweet plus
    /// browser chrome and the signal averages into mush. Measured on the real corpus, a
    /// capture containing the exact phrase being searched scored **0.306** as a whole,
    /// below unrelated pages at 0.44, because most of those characters were navigation.
    /// The same text in passages scores far higher, since one passage is mostly the tweet.
    ///
    /// A capture is therefore represented by its best-matching passage, not its average.
    static func passages(_ text: String, size: Int = 220, stride: Int = 150) -> [String] {
        let clean = MemoryText.collapseWhitespace(text)
        guard clean.count >= 40 else { return clean.isEmpty ? [] : [clean] }
        var out: [String] = []
        var start = clean.startIndex
        while start < clean.endIndex {
            let end = clean.index(start, offsetBy: size, limitedBy: clean.endIndex) ?? clean.endIndex
            let passage = String(clean[start..<end])
            if passage.count >= 40 { out.append(passage) }
            guard let next = clean.index(start, offsetBy: stride, limitedBy: clean.endIndex),
                  next < clean.endIndex else { break }
            start = next
            // A handful of overlapping windows is plenty; whole pages are mostly furniture.
            if out.count >= 12 { break }
        }
        return out.isEmpty ? [clean] : out
    }

    /// Embeds every passage of a capture. The unit that gets stored, and the expensive one:
    /// up to 12 passages at ~4ms each.
    static func passageVectors(_ text: String) -> [[Float]] {
        passages(text).compactMap { embed($0) }
    }

    /// The best score any of these passage vectors achieves against the query vector.
    ///
    /// A capture is represented by its best passage rather than its average, for the reason
    /// ``passages(_:size:stride:)`` explains. Takes vectors rather than text because the
    /// vectors now come out of the database: computing them here was the single slowest thing
    /// Memoir did, at 3665ms per search on 482 captures.
    static func bestPassageScore(_ vectors: [[Float]], query: [Float]) -> Double {
        var best = 0.0
        for v in vectors { best = max(best, cosine(query, v)) }
        return best
    }

    public static func cosine(_ a: [Float], _ b: [Float]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for i in 0..<a.count {
            dot += a[i] * b[i]
            na += a[i] * a[i]
            nb += b[i] * b[i]
        }
        guard na > 0, nb > 0 else { return 0 }
        return Double(dot / (sqrt(na) * sqrt(nb)))
    }

    /// Captures most similar in meaning to the query.
    ///
    /// - Returns: capture ids with their similarity, best first. Empty when embeddings are
    ///   unavailable, so callers fall back to keyword search rather than failing.
    public func search(_ query: String, limit: Int = 12, minimumScore: Double = 0.35) async throws -> [(id: ID, score: Double)] {
        guard let q = Self.embed(query) else { return [] }
        try await loadCacheIfNeeded()
        guard !cache.isEmpty else { return [] }

        // Two stages, for the same reason the question router has two: the cheap one
        // narrows, the accurate one ranks.
        //
        // Whole-capture vectors are a coarse filter: good enough to find candidates,
        // too blunt to order them, because a long page averages its own meaning away.
        // Re-scoring the shortlist passage by passage is what actually surfaces the one
        // sentence you were looking for.
        var coarse: [(ID, Double)] = []
        coarse.reserveCapacity(cache.count)
        for entry in cache {
            coarse.append((entry.id, Self.cosine(q, entry.vector)))
        }
        coarse.sort { $0.1 > $1.1 }

        // Six candidates per result: measured, not assumed, now that a candidate is cheap.
        // On the real 482-vector corpus, release build, one search of the same query at
        // increasing widths:
        //
        //       6 candidates  5.3ms     72 candidates  5.6ms
        //      36 candidates  5.2ms    144 candidates  6.7ms
        //
        // The whole shortlist costs ~0.3ms; the other 5ms is embedding the query (~4ms) and
        // the coarse scan. So narrowing it would save nothing measurable and could only lose
        // recall, since the coarse whole-capture score is the blunt measure this stage exists
        // to correct: the capture the question is about routinely sits below rank 12 in it.
        let shortlist = coarse.prefix(limit * 6).map(\.0)
        let stored = (try? await store.passageVectors(for: shortlist)) ?? [:]

        var scored: [(ID, Double)] = []
        for id in shortlist {
            // Written as an if rather than `??` because that operator cannot await, and
            // because the fallback must not run when the vectors are already known: it is the
            // 4ms-per-passage path this whole change exists to avoid.
            var vectors = stored[id]
            if vectors == nil { vectors = await passageVectors(computingFor: id) }
            guard let vectors else { continue }
            let score = Self.bestPassageScore(vectors, query: q)
            if score >= minimumScore { scored.append((id, score)) }
        }
        scored.sort { $0.1 > $1.1 }
        return Array(scored.prefix(limit)).map { (id: $0.0, score: $0.1) }
    }

    /// Passage vectors for a capture that has none stored: computed now, and remembered.
    ///
    /// Reached when a capture arrived after the last backfill, or when the database predates
    /// schema v4 and nothing has drained the backlog yet. Writing them back here is what
    /// makes such a capture slow once instead of slow forever, and it is the only reason a
    /// user who never runs `memoir-ask --embed` still ends up with a fast memory. A read-only
    /// store (the MCP server opens one) simply stays slow rather than failing.
    ///
    /// - Returns: nil when the capture row is gone, so the caller skips it rather than
    ///   scoring an absent capture at zero.
    private func passageVectors(computingFor id: ID) async -> [[Float]]? {
        guard let capture = try? await store.capture(id: id) else { return nil }
        passageCacheMisses += 1
        let computed = Self.passageVectors(capture.text)
        if !store.isReadOnly {
            try? await store.setPassageVectors(captureID: id, vectors: computed)
        }
        return computed
    }

    /// Embeds any captures that do not yet have a vector.
    ///
    /// Runs off the capture hot path: embedding is cheap but not free, and capture must
    /// never wait on it.
    @discardableResult
    public func backfill(limit: Int = 2_000) async throws -> Int {
        let pending = try await store.capturesMissingEmbeddings(limit: limit)
        guard !pending.isEmpty else { return 0 }
        var written = 0
        for capture in pending {
            // Never index a conversation with an assistant.
            //
            // Questions embed near other questions, so a search for "that tweet about
            // claude skills wrapped in an sms app" returned eight prompts I had typed to
            // Claude and not one piece of actual content. What you asked is not what you
            // saw, and only the latter is worth remembering.
            guard !RuleExtractor.isConversationalAI(capture) else {
                try await store.setEmbedding(captureID: capture.id, vector: [])
                continue
            }
            guard let v = Self.embed(capture.text) else {
                // Mark it attempted so an unembeddable capture is not retried forever.
                try await store.setEmbedding(captureID: capture.id, vector: [])
                continue
            }
            try await store.setEmbedding(captureID: capture.id, vector: v)
            // Its passages too, in the same pass. They cost ~50ms per capture here and 3.8
            // seconds per search when a search has to compute them instead.
            try await store.setPassageVectors(
                captureID: capture.id, vectors: Self.passageVectors(capture.text))
            written += 1
        }
        cacheLoadedAt = nil
        Log.shared.debug("semantic index embedded \(written) captures")
        return written
    }

    /// Embeds the passages of captures that already have a whole-capture vector but no
    /// passage vectors: every capture indexed before schema v4.
    ///
    /// Separate from ``backfill(limit:)`` because it drains a different backlog: that one
    /// closes the gap between captures and vectors, this one closes the gap between an old
    /// database and this one. Also off the hot path, for the same reason.
    @discardableResult
    public func backfillPassages(limit: Int = 500) async throws -> Int {
        let pending = try await store.capturesMissingPassageVectors(limit: limit)
        guard !pending.isEmpty else { return 0 }
        for capture in pending {
            // An empty array is still written: it records "attempted, nothing embeddable",
            // which is what stops this capture being retried on every pass forever.
            try await store.setPassageVectors(
                captureID: capture.id, vectors: Self.passageVectors(capture.text))
        }
        Log.shared.debug("semantic index embedded passages for \(pending.count) captures")
        return pending.count
    }

    /// Loads vectors into memory, refreshing periodically.
    private func loadCacheIfNeeded() async throws {
        if let loaded = cacheLoadedAt, Date().timeIntervalSince(loaded) < 60, !cache.isEmpty {
            return
        }
        let rows = try await store.allEmbeddings(limit: Self.bruteForceCeiling)
        cache = rows.filter { !$0.vector.isEmpty }
        cacheLoadedAt = Date()
        if rows.count >= Self.bruteForceCeiling {
            Log.shared.warn("semantic index hit the brute-force ceiling (\(Self.bruteForceCeiling)); an approximate index is now worth considering")
        }
    }
}
