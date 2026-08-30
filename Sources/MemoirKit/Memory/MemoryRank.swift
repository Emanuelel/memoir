import Foundation

/// Ranking signals that sit between search and the context packet.
///
/// Two things live here, both borrowed from what the hosted memory services converged on
/// in 2026, and both adjusted for the fact that Memoir remembers a *screen* rather than a
/// *conversation*.
///
/// **Entity linking.** Keyword search and cosine similarity both search for the words the
/// question used. Neither can follow a name to its other names. The memory knows that
/// `Fenwick Migration` is also `FEN`; the capture stream says `FEN-42`; the question says
/// "fenwick". Nothing matches, because no single string is in two of those three
/// places. Resolving the question to entities first, then searching the stream for *their*
/// names, is the third retrieval signal, and it is the only one that can cross a rename.
///
/// **Temporal decay, on beliefs and not on events.** The services that ship decay apply it
/// to memories wholesale, which is right for their data: a memory that says "works at Acme"
/// is a standing claim, and a standing claim goes stale. Memoir's captures are not claims,
/// they are *events with a timestamp*: a page read in March is not a stale fact, it is
/// March. Decaying them would break the question a memory is asked most often ("what was
/// that thing I saw"), which is precisely the question whose answer is old.
///
/// So decay lands on entities, where the staleness problem actually is: an inferred project
/// nobody has touched in three months should not arrive in a context packet weighted the
/// same as the one on screen right now. That is the port worth making, and the capture
/// ranking is deliberately left alone.
public enum MemoryRank {

    // MARK: - Entity linking

    /// Alternate names for these entities that the question did not already use.
    ///
    /// Names the asker typed are dropped, and not as an optimisation: keyword search has
    /// already searched for those, so re-searching them would fill the fused ranking with
    /// four copies of one signal and drown the signals that disagree with it. What is left
    /// is exactly the new information the ontology contributes: the names the user *didn't*
    /// say but the corpus might use.
    ///
    /// - Parameters:
    ///   - entities: Entities the question resolved to, best first.
    ///   - question: The raw question, to subtract the names already in it.
    ///   - limit: Maximum names returned, best-entity-first.
    /// - Returns: Distinct names, in entity order, aliases before titles within one entity.
    public static func linkedNames(
        for entities: [Entity], question: String, limit: Int = 6
    ) -> [String] {
        let asked = " " + MemoryText.normalizedTitle(question) + " "
        var out: [String] = []
        var seen = Set<String>()
        for entity in entities where !entity.deleted {
            // Aliases first. A title usually shares words with whatever matched the entity
            // in the first place; an alias is the name that got the entity *missed*.
            for name in entity.aliases + [entity.title] {
                let normalized = MemoryText.normalizedTitle(name)
                // Two characters is a coin toss, not a name: "go", "id", "pr" would each
                // match a large fraction of any working day.
                guard normalized.count >= 3, seen.insert(normalized).inserted else { continue }
                // Already in the question, so already searched.
                guard !asked.contains(" " + normalized + " ") else { continue }
                out.append(name)
                if out.count >= limit { return out }
            }
        }
        return out
    }

    // MARK: - Temporal decay

    /// How much a recent entity outranks a stale one.
    static let freshWeight = 1.5
    /// The floor. A stale entity is demoted, never removed: it is still on the record, and
    /// dropping it would be the memory quietly forgetting rather than the ranking deciding.
    static let staleWeight = 0.3
    /// Where the curve crosses 1.0: below this an entity is boosted, above it damped.
    /// Set from the shape of a working fortnight rather than from a benchmark.
    static let decayTimeConstant: TimeInterval = 30 * 24 * 60 * 60

    /// A multiplier on an entity's search score, from how long ago it was last touched.
    ///
    /// Runs from ``freshWeight`` at zero age to ``staleWeight`` at roughly seven weeks,
    /// crossing 1.0 near a fortnight.
    ///
    /// **Nothing the user wrote ever goes stale.** An authored, corrected or pinned entity
    /// is weighed at ``freshWeight`` forever, permanently as recent as the thing on screen
    /// right now. The user put it there on purpose, and a ranking that buries it after a
    /// quiet month is the ranking overruling the person, which is the one thing this memory
    /// does not do.
    ///
    /// The ceiling rather than a neutral 1.0, and the difference is not cosmetic. At 1.0 a
    /// boost is still enough to climb *past* an authored entity: a guess at rank 2 scores
    /// `1.5/62`, an authored fact at rank 1 scores `1.0/61`, and the guess wins. A test
    /// caught exactly that. Pinning the exemption at the ceiling means freshness can never
    /// overtake authorship; only a better search rank can, which is the intended way to
    /// beat it.
    ///
    /// A completed commitment is damped to the floor immediately. It is done; it is history
    /// the moment it is ticked off, whatever its timestamp says.
    public static func recencyWeight(for entity: Entity, now: Date) -> Double {
        if entity.source == .authored || entity.corrected || entity.pinned { return freshWeight }
        if entity.kind == .commitment, entity.completedAt != nil { return staleWeight }
        let age = max(0, now.timeIntervalSince(entity.updatedAt))
        let decayed = freshWeight * exp(-age / decayTimeConstant)
        return min(freshWeight, max(staleWeight, decayed))
    }

    /// Entities ordered by search rank and recency together, best first.
    ///
    /// Rank is folded in reciprocally, the same way ``MemoryService/reciprocalRankFusion(_:k:)``
    /// folds the capture lists: the position an entity reached is comparable across searches
    /// in a way a raw FTS score is not. Recency then multiplies that, so a fortnight-old
    /// project can beat a barely-matching one from the spring without ever hiding it.
    ///
    /// - Parameters:
    ///   - entities: Search results, best first, already deduplicated.
    ///   - now: The clock, injected so the curve is testable.
    public static func byRelevanceAndRecency(_ entities: [Entity], now: Date, k: Double = 60) -> [Entity] {
        var scored: [(entity: Entity, score: Double)] = []
        scored.reserveCapacity(entities.count)
        for (index, entity) in entities.enumerated() {
            let rank: Double = 1 / (k + Double(index + 1))
            scored.append((entity, rank * recencyWeight(for: entity, now: now)))
        }
        scored.sort { a, b in
            a.score == b.score ? a.entity.updatedAt > b.entity.updatedAt : a.score > b.score
        }
        return scored.map(\.entity)
    }
}
