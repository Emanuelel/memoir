import Foundation

/// The output of one extraction pass: the entities that were found and the
/// provenance rows that tie each of them back to the capture they came from.
///
/// Every entity in `entities` is guaranteed to have at least one matching row in
/// `provenance`. That is the traceability law of the design: nothing enters memory
/// without a pointer to the exact text it was derived from.
public struct ExtractionResult: Sendable, Equatable {
    /// Entities discovered by this pass. Not yet reconciled against the store.
    public let entities: [Entity]
    /// Rows tying an entity field to the capture and snippet it was derived from.
    public let provenance: [Provenance]

    /// Creates a result. Both collections default to empty.
    public init(entities: [Entity] = [], provenance: [Provenance] = []) {
        self.entities = entities
        self.provenance = provenance
    }

    /// A pass that found nothing.
    public static let empty = ExtractionResult()

    /// True when nothing was extracted.
    public var isEmpty: Bool { entities.isEmpty && provenance.isEmpty }

    /// Layers `other` on top of the receiver without ever discarding what the
    /// receiver already found.
    ///
    /// Entities that share a kind and a normalised title are merged: confidence can
    /// rise, empty fields can be filled, and the incoming provenance is re-pointed at
    /// the surviving entity ID. Titles are never replaced, and an entity marked
    /// `corrected` is never modified beyond its confidence.
    ///
    /// This is how the LLM extractor sits on top of the rule extractor rather than
    /// replacing it.
    public func merging(_ other: ExtractionResult) -> ExtractionResult {
        guard !other.isEmpty else { return self }
        guard !isEmpty else { return other }

        var merged = entities
        var index: [String: Int] = [:]
        for (i, e) in merged.enumerated() {
            index[MemoryText.dedupeKey(kind: e.kind, title: e.title)] = i
        }

        var remap: [ID: ID] = [:]
        for candidate in other.entities {
            let key = MemoryText.dedupeKey(kind: candidate.kind, title: candidate.title)
            if let i = index[key] {
                remap[candidate.id] = merged[i].id
                let (entity, _) = MemoryMerge.merged(
                    existing: merged[i],
                    candidate: candidate,
                    now: max(merged[i].updatedAt, candidate.updatedAt)
                )
                merged[i] = entity
            } else {
                remap[candidate.id] = candidate.id
                index[key] = merged.count
                merged.append(candidate)
            }
        }

        var rows = provenance
        var seen = Set(rows.map(MemoryText.provenanceKey))
        for row in other.provenance {
            let entityID = remap[row.entityID] ?? row.entityID
            let mapped = Provenance(
                id: MemoryText.stableID("prov", entityID, row.captureID, row.field, row.snippet),
                entityID: entityID,
                captureID: row.captureID,
                field: row.field,
                snippet: row.snippet,
                ts: row.ts,
                extractor: row.extractor
            )
            let key = MemoryText.provenanceKey(mapped)
            guard seen.insert(key).inserted else {
                // Both passes found this evidence. That is the interesting case, and dropping
                // the second one would throw away the only record that the model agreed,
                // which on a corpus where the rules are good is most of what the model does.
                if let i = rows.firstIndex(where: { MemoryText.provenanceKey($0) == key }) {
                    rows[i].extractor.formUnion(mapped.extractor)
                }
                continue
            }
            rows.append(mapped)
        }

        return ExtractionResult(entities: merged, provenance: rows)
    }
}

/// Turns raw captures into structured memory.
///
/// Implementations must be cheap to call repeatedly and must never mutate the
/// store: `MemoryService` owns all writes.
public protocol Extractor: Sendable {
    /// Extracts entities and provenance from a batch of captures.
    ///
    /// - Parameter captures: the captures to read, oldest or newest order is irrelevant.
    /// - Returns: entities plus the provenance rows proving where each came from.
    func extract(from captures: [CaptureEvent]) async throws -> ExtractionResult
}
