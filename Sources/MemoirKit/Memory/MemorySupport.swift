import CryptoKit
import Foundation

// MARK: - Text utilities

/// Internal string helpers shared by the extractors and by `MemoryService`.
///
/// Everything here is pure and deterministic: the same input always produces the
/// same output, which is what lets the rule extractor be re-run over the same
/// captures without producing duplicate entities.
enum MemoryText {

    /// Collapses every run of whitespace (including newlines and tabs) into a single space.
    static func collapseWhitespace(_ s: String) -> String {
        s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// Collapses whitespace, then strips list bullets, quote markers and stray
    /// punctuation from the front and back of the string.
    static func clean(_ s: String) -> String {
        var out = collapseWhitespace(s)
        let leading = CharacterSet(charactersIn: "-*•·>|#=+~\u{2013}\u{2014}\u{2022} \t")
        while let first = out.unicodeScalars.first, leading.contains(first) {
            out.removeFirst()
        }
        while let last = out.last, last == " " || last == "\t" {
            out.removeLast()
        }
        return out
    }

    /// Truncates on a word boundary and marks the cut with an ellipsis.
    static func truncate(_ s: String, max: Int) -> String {
        guard max > 1, s.count > max else { return s }
        let cut = s.index(s.startIndex, offsetBy: max)
        var head = String(s[s.startIndex..<cut])
        if let space = head.lastIndex(of: " "),
           head.distance(from: head.startIndex, to: space) > max / 2 {
            head = String(head[head.startIndex..<space])
        }
        let trimmed = head.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? trimmed : trimmed + "\u{2026}"
    }

    /// Case, accent and punctuation insensitive form of a title, used as the dedupe key.
    ///
    /// `"Sarah O'Neill"`, `"sarah oneill"` and `"SARAH  ONEILL"` all normalise to
    /// the same string, so extraction can never create three copies of one person.
    static func normalizedTitle(_ s: String) -> String {
        let folded = s.folding(
            options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        var buffer = ""
        buffer.reserveCapacity(folded.count)
        for ch in folded {
            if ch.isLetter || ch.isNumber {
                buffer.append(ch)
            } else if ch == "-" || ch == "_" {
                buffer.append(ch)
            } else {
                buffer.append(" ")
            }
        }
        var words = buffer.split(separator: " ").map(String.init)
        if words.count > 1, words[0] == "the" { words.removeFirst() }
        return words.joined(separator: " ")
    }

    /// The identity of an entity for merge purposes: kind plus normalised title.
    static func dedupeKey(kind: EntityKind, title: String) -> String {
        "\(kind.rawValue)|\(normalizedTitle(title))"
    }

    /// The identity of a provenance row: nothing about it may repeat.
    static func provenanceKey(_ p: Provenance) -> String {
        "\(p.entityID)|\(p.captureID)|\(p.field)|\(normalizedTitle(p.snippet))"
    }

    /// A deterministic UUID-shaped identifier derived from the given parts.
    ///
    /// Stable IDs mean a second extraction pass over the same text produces the
    /// same entity ID, so re-running consolidation is idempotent.
    static func stableID(_ parts: String...) -> ID { stableID(parts) }

    /// A deterministic UUID-shaped identifier derived from the given parts.
    static func stableID(_ parts: [String]) -> ID {
        let joined = parts.joined(separator: "\u{1}")
        let digest = SHA256.hash(data: Data(joined.utf8))
        let hex = digest.prefix(16).map { String(format: "%02x", $0) }.joined()
        let chars = Array(hex)
        func slice(_ from: Int, _ to: Int) -> String { String(chars[from..<to]) }
        return "\(slice(0, 8))-\(slice(8, 12))-\(slice(12, 16))-\(slice(16, 20))-\(slice(20, 32))"
    }

    /// Words that carry no search signal. Used when turning a question into keywords.
    static let queryStopwords: Set<String> = [
        "the", "and", "for", "with", "what", "when", "where", "who", "whom", "whose", "why",
        "how", "did", "does", "was", "were", "are", "you", "your", "yours", "our", "his", "her",
        "him", "she", "they", "them", "this", "that", "these", "those", "there", "then", "than",
        "from", "about", "into", "over", "under", "again", "any", "all", "some", "not", "but",
        "can", "could", "would", "should", "will", "shall", "have", "has", "had", "been", "being",
        "get", "got", "him", "its", "it's", "i'm", "i've", "me", "my", "mine", "we", "us", "yes",
        "no", "please", "tell", "show", "give", "list", "say", "said", "know", "think", "need",
        "want", "make", "made", "much", "many", "more", "most", "just", "now", "today", "yesterday",
        "tomorrow", "week", "day", "days", "time", "thing", "things", "stuff",
    ]

    /// Lowercased keyword tokens from free text, longest first, stopwords removed.
    static func keywords(_ s: String, limit: Int = 8) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        let folded = s.folding(
            options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        for raw in folded.split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "-") }) {
            let token = String(raw)
            guard token.count >= 3, !queryStopwords.contains(token) else { continue }
            if seen.insert(token).inserted { out.append(token) }
        }
        out.sort { $0.count > $1.count }
        return Array(out.prefix(limit))
    }

    /// Splits text into scannable segments: one per line, long lines split by sentence.
    ///
    /// On-screen text is frequently unpunctuated (chat rows, table cells, menus), so
    /// lines are the primary unit and sentences only apply inside very long lines.
    static func segments(in text: String) -> [NSRange] {
        var out: [NSRange] = []
        let whole = text.startIndex..<text.endIndex
        text.enumerateSubstrings(in: whole, options: [.byLines]) { sub, range, _, _ in
            guard let sub, !sub.trimmingCharacters(in: .whitespaces).isEmpty else { return }
            let base = NSRange(range, in: text)
            if sub.count <= 240 {
                out.append(base)
                return
            }
            var added = false
            let inner = sub.startIndex..<sub.endIndex
            sub.enumerateSubstrings(in: inner, options: [.bySentences]) { piece, pieceRange, _, _ in
                guard let piece, !piece.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                let r = NSRange(pieceRange, in: sub)
                out.append(NSRange(location: base.location + r.location, length: r.length))
                added = true
            }
            if !added { out.append(base) }
        }
        if out.isEmpty {
            let ns = text as NSString
            if ns.length > 0 { out.append(NSRange(location: 0, length: ns.length)) }
        }
        return out
    }
}

// MARK: - Segment index

/// Sorted segment ranges with a fast "which segment contains this offset" lookup,
/// used to turn a regex match into a human-readable provenance snippet.
struct SegmentIndex {
    let ranges: [NSRange]

    init(text: String) {
        self.ranges = MemoryText.segments(in: text).sorted { $0.location < $1.location }
    }

    /// The segment containing `location`, or nil when the offset falls in a gap.
    func range(containing location: Int) -> NSRange? {
        var lo = 0
        var hi = ranges.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            let r = ranges[mid]
            if location < r.location {
                hi = mid - 1
            } else if location >= r.location + r.length {
                lo = mid + 1
            } else {
                return r
            }
        }
        return nil
    }

    /// A cleaned, length-capped snippet of the segment around `location`.
    func snippet(for location: Int, in ns: NSString, max: Int = 240) -> String {
        if let r = range(containing: location) {
            return MemoryText.truncate(MemoryText.clean(ns.substring(with: r)), max: max)
        }
        let start = Swift.max(0, location - max / 2)
        let length = Swift.min(max, ns.length - start)
        guard length > 0 else { return "" }
        return MemoryText.truncate(MemoryText.clean(ns.substring(with: NSRange(location: start, length: length))), max: max)
    }
}

// MARK: - Merge policy

/// The single place where two versions of an entity are combined.
///
/// **The law:** an entity whose `corrected` flag is true was edited by the user, and one
/// whose `source` is `authored` was written by the user in the first place. Extraction may
/// raise the confidence of either and attach new provenance, but it may never change the
/// title, detail, kind or due date of either. Ever.
///
/// The two flags are not the same fact and neither implies the other. `corrected` marks a
/// guess the user repaired; `authored` marks a row that was never a guess, so there is
/// nothing in it for a guess to improve.
///
/// `deleted` is absent from every branch below on purpose. A merge starts from `existing`
/// and never assigns that field, so no amount of re-observation can resurrect a row the
/// user finished with.
///
/// `aliases` sit outside both laws: they are additional *names* for a thing, not claims
/// about it, so both sides' aliases are unioned no matter who wrote them. More names for
/// the same thing only ever helps the matcher find it.
enum MemoryMerge {

    /// Merges `candidate` into `existing` and reports whether anything actually changed.
    ///
    /// - Parameters:
    ///   - existing: the entity already in the store (or already in the result set).
    ///   - candidate: freshly extracted evidence for the same normalised title + kind.
    ///   - now: timestamp used for `updatedAt` when a field changes.
    ///   - boost: how much corroboration from a second source raises confidence.
    /// - Returns: the merged entity and a flag that is true only when a stored field changed.
    static func merged(
        existing: Entity,
        candidate: Entity,
        now: Date = Date(),
        boost: Double = 0.05
    ) -> (entity: Entity, changed: Bool) {
        var out = existing
        var changed = false

        let raised = min(0.99, max(existing.confidence, candidate.confidence) + boost)
        if raised > existing.confidence + 0.0001 {
            out.confidence = raised
            changed = true
        }

        // Provisional only ever clears, never sets. A commitment first read off a web
        // page and later seen somewhere the user actually writes (a note, a message they
        // sent, an explicit push) has had its ownership established, and the flag is the
        // record of a doubt that no longer applies. The reverse would let one stray tab
        // silence a real promise.
        if out.provisional, !candidate.provisional {
            out.provisional = false
            changed = true
        }

        // Aliases accumulate from either side, ahead of every guard below: they are
        // names, not claims, so even a corrected or authored row may learn that the
        // same thing is also called "FEN-42".
        let unionAliases = mergedAliases(existing.aliases, candidate.aliases)
        if unionAliases != out.aliases {
            out.aliases = unionAliases
            changed = true
        }

        // Source only ever climbs. Extraction re-observing a sentence the user typed is
        // corroboration of the claim, not evidence that Memoir inferred it after all, so a
        // merge that let `authored` fall back to `inferred` would silently relabel the
        // user's own words as a guess, and the row would then be fair game for the very
        // overwrite the guard below exists to prevent.
        if candidate.source.outranks(existing.source) {
            out.source = candidate.source
            changed = true
        }

        // User corrections and authored rows are permanent. Confidence may rise; nothing
        // else moves. The second clause is what stops a confident extractor from rewriting
        // a commitment the user pushed in their own words: the same failure as CF-1, one
        // step earlier, because here there was never a guess to correct. Corrections are
        // checked first so that in the one case where both point at the user, a correction
        // met by a later authored collision, the correction stands: it is the user's
        // judgement about this exact row rather than about a phrase that happens to collide.
        guard !existing.corrected, !existing.source.outranks(candidate.source) else {
            if changed { out.updatedAt = now }
            return (out, changed)
        }

        // The other direction: the user has now said out loud what Memoir had only guessed, so
        // their wording replaces the guess outright rather than filling its gaps. Only an
        // authored candidate reaches this branch, so the "first spelling wins" rule below
        // still holds for everything extraction proposes. A nil field is silence, not an
        // instruction to clear: only a direct edit empties a field.
        if candidate.source.outranks(existing.source) {
            let title = MemoryText.clean(candidate.title)
            if !title.isEmpty, title != out.title {
                out.title = title
                changed = true
            }
            if let detail = candidate.detail, !detail.isEmpty, detail != out.detail {
                out.detail = detail
                changed = true
            }
            if let due = candidate.dueAt, due != out.dueAt {
                out.dueAt = due
                changed = true
            }
            if changed { out.updatedAt = now }
            return (out, changed)
        }

        switch (existing.source, candidate.source) {
        case (.authored, .inferred):
            // Law 2: a guess never touches what the user wrote. Confidence and
            // aliases may have moved above; the fields themselves are frozen.
            if changed { out.updatedAt = now }
            return (out, changed)

        case (.inferred, .authored):
            // The inferred row is adopted by the authored version: the user's own
            // words replace the guess wholesale, and the row is authored from now on.
            if out.title != candidate.title { out.title = candidate.title; changed = true }
            if let detail = candidate.detail, detail != out.detail { out.detail = detail; changed = true }
            if let due = candidate.dueAt, due != out.dueAt { out.dueAt = due; changed = true }
            out.source = .authored
            changed = true
            out.updatedAt = now
            return (out, changed)

        case (.authored, .authored):
            // Vault re-import: the file is canon, so its current content wins.
            // The user editing their own note is the one legitimate way an
            // authored field changes.
            if out.detail != candidate.detail, candidate.detail != nil {
                out.detail = candidate.detail
                changed = true
            }
            if let due = candidate.dueAt, due != out.dueAt { out.dueAt = due; changed = true }
            if changed { out.updatedAt = now }
            return (out, changed)

        case (.inferred, .inferred):
            break // the ordinary path below
        }

        // Titles are never silently rewritten. The first observed spelling wins and
        // only the user can change it.
        if (out.detail?.isEmpty ?? true), let detail = candidate.detail, !detail.isEmpty {
            out.detail = detail
            changed = true
        }
        if out.dueAt == nil, let due = candidate.dueAt {
            out.dueAt = due
            changed = true
        }

        if changed { out.updatedAt = now }
        return (out, changed)
    }

    /// Union of two alias lists, order-preserving, case-insensitively deduped.
    static func mergedAliases(_ a: [String], _ b: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for alias in a + b {
            let trimmed = alias.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed.lowercased()).inserted else { continue }
            out.append(trimmed)
        }
        return out
    }
}

// MARK: - Extraction builder

/// Accumulates entities and provenance during a single extraction pass, deduping
/// as it goes so a phrase repeated across twenty captures produces one entity with
/// several provenance rows rather than twenty entities.
struct ExtractionBuilder {
    /// Hard ceiling on entities produced by one pass. Protects against a pathological
    /// screen full of capitalised words turning into thousands of rows.
    /// Which pass this builder is emitting for. Stamped on every provenance row it produces,
    /// so the decision is made once per extractor rather than at each call site.
    var extractor: ExtractorMask = .none

    var maxEntities: Int = 400
    /// Hard ceiling on provenance rows kept per entity in a single pass.
    var maxProvenancePerEntity: Int = 6

    private var byKey: [String: Int] = [:]
    private var entities: [Entity] = []
    private var provenance: [Provenance] = []
    private var provenanceKeys: Set<String> = []
    private var provenanceCounts: [ID: Int] = [:]

    /// Adds (or merges into) an entity and records the snippet it came from.
    ///
    /// - Returns: the entity ID, or nil when the candidate was rejected (empty or
    ///   over the per-pass ceiling).
    @discardableResult
    mutating func add(
        kind: EntityKind,
        title rawTitle: String,
        detail: String? = nil,
        dueAt: Date? = nil,
        confidence: Double,
        capture: CaptureEvent,
        snippet rawSnippet: String,
        field: String = "title",
        provisional: Bool = false
    ) -> ID? {
        let title = MemoryText.clean(rawTitle)
        let normalized = MemoryText.normalizedTitle(title)
        guard title.count >= 2, normalized.count >= 2 else { return nil }

        // An application is not a project, however often its name is on the screen.
        //
        // Chrome puts "— Google Chrome" at the end of every window title it has, so the
        // Title-Case rule eventually read one of them as a project name. That single row —
        // inferred, one title-only sighting, minted in an afternoon — went on to match 47.3%
        // of every capture in the corpus and inflated every coverage figure the product
        // reported by about 13.6 points of the clock.
        //
        // Caught here as well as at match time because the two failures are different: the
        // matcher stops the row labelling anything, and this stops the row existing. A memory
        // that quietly holds "Google Chrome" as one of the user's projects is wrong even on
        // the day nothing is attributed to it.
        if kind == .project, normalized == MemoryText.normalizedTitle(capture.appName) {
            return nil
        }

        // Kinds nothing reads, and nothing should keep making.
        //
        // Measured on a real vault: thread 825 rows, note 115 inferred, decision 63 — 48% of a
        // 2,095-row store that no surface renders and no query returns. What is in them is not
        // borderline. The threads are Instagram hashtags and CSS hex colours; the
        // highest-evidence decisions are an Apache licence header, an assistant's replies
        // quoted back at itself, and a stranger's post.
        //
        // Each was retired for its own reason and both are recorded where they happened:
        // `Ontology.labelKinds` explains why a thread may not name an hour, after an email
        // subject line billed one as "**lunch thursday, works for me**, 24m"; `place` yields
        // one row from nine years of photographs because 0.9% of them carry a coordinate, and
        // the honest response to an empty geography is not to lower the bar.
        //
        // Refused here rather than by deleting the enum cases, because existing rows must
        // still decode: a database written by an older build opens in this one, and a kind
        // this build cannot name would read as `.note` and quietly become something else.
        // Reading stays; writing stops.
        if ExtractionBuilder.retiredKinds.contains(kind) { return nil }

        let key = "\(kind.rawValue)|\(normalized)"
        let entityID: ID
        if let index = byKey[key] {
            let candidate = Entity(
                id: entities[index].id,
                kind: kind,
                title: title,
                detail: detail,
                dueAt: dueAt,
                confidence: confidence,
                createdAt: entities[index].createdAt,
                updatedAt: capture.ts
            )
            let (merged, _) = MemoryMerge.merged(existing: entities[index], candidate: candidate, now: capture.ts)
            entities[index] = merged
            entityID = merged.id
        } else {
            guard entities.count < maxEntities else { return nil }
            let id = MemoryText.stableID("entity", kind.rawValue, normalized)
            let entity = Entity(
                id: id,
                kind: kind,
                title: title,
                detail: detail,
                dueAt: dueAt,
                confidence: min(max(confidence, 0.05), 0.95),
                pinned: false,
                corrected: false,
                deleted: false,
                provisional: provisional,
                createdAt: capture.ts,
                updatedAt: capture.ts
            )
            byKey[key] = entities.count
            entities.append(entity)
            entityID = id
        }

        addProvenance(entityID: entityID, capture: capture, field: field, snippet: rawSnippet)
        if let due = dueAt {
            addProvenance(
                entityID: entityID,
                capture: capture,
                field: "dueAt",
                snippet: rawSnippet,
                extra: ISO8601DateFormatter().string(from: due)
            )
        }
        return entityID
    }

    /// Records a provenance row. Every entity produced by extraction gets at least one.
    mutating func addProvenance(
        entityID: ID,
        capture: CaptureEvent,
        field: String,
        snippet rawSnippet: String,
        extra: String? = nil
    ) {
        let count = provenanceCounts[entityID] ?? 0
        guard count < maxProvenancePerEntity else { return }
        var snippet = MemoryText.truncate(MemoryText.clean(rawSnippet), max: 280)
        if snippet.isEmpty { snippet = MemoryText.truncate(MemoryText.clean(capture.text), max: 120) }
        guard !snippet.isEmpty else { return }
        if let extra { snippet = "\(snippet) [\(extra)]" }

        let row = Provenance(
            id: MemoryText.stableID("prov", entityID, capture.id, field, snippet),
            entityID: entityID,
            captureID: capture.id,
            field: field,
            snippet: snippet,
            ts: capture.ts,
            extractor: extractor,
            strength: ExtractionBuilder.strength(of: rawSnippet, in: capture)
        )
        let key = MemoryText.provenanceKey(row)
        guard provenanceKeys.insert(key).inserted else { return }
        provenance.append(row)
        provenanceCounts[entityID] = count + 1
    }

    /// Kinds extraction may no longer produce. See the guard in ``add(kind:title:...)``.
    ///
    /// Deliberately a set rather than deleted enum cases. `EntityKind` still names all of
    /// them, `Store.decodeEntity` still reads them, and every row already on disk still opens
    /// and still renders in the memory browser. This stops the store growing, and takes
    /// nothing away from anyone who already has one.
    static let retiredKinds: Set<EntityKind> = [.thread, .decision, .place]

    /// Where in the capture this evidence sat. See ``EvidenceStrength``.
    ///
    /// Deterministic, from what the capture already carries — no model, no heuristic score.
    /// Three places count as the screen speaking, in the order a reader would rank them:
    /// the window title, which names what the window *is*; the viewport, which is what was
    /// actually in front of the user; and the opening of the body, which is the part the
    /// ontology matcher itself reads and therefore the part the product already treats as
    /// what the screen was about.
    ///
    /// Anything else is `incidental`: true, present, and possibly a related-links rail or a
    /// footer. Measured on a real vault, roughly half of all stored characters sat outside
    /// the viewport, so this is not a rare case being flagged — it is half the corpus finally
    /// being distinguished from the other half.
    ///
    /// `visibleText` nil means the geometry was never resolved, which is not the same as
    /// "nothing was visible". An unresolved viewport must not demote every citation on that
    /// capture, so the body-opening test carries it.
    static func strength(of rawSnippet: String, in capture: CaptureEvent) -> EvidenceStrength {
        let needle = MemoryText.clean(rawSnippet).lowercased()
        guard !needle.isEmpty else { return .direct }

        if let title = capture.windowTitle?.lowercased(), title.contains(needle) { return .direct }
        if let visible = capture.visibleText?.lowercased(), !visible.isEmpty {
            return visible.contains(needle) ? .direct : .incidental
        }
        // The opening the matcher reads. Ontology.match caps body text at 600 characters, so
        // beyond that is text no label was ever drawn from.
        let opening = capture.text.prefix(600).lowercased()
        return opening.contains(needle) ? .direct : .incidental
    }

    /// True when an entity with this kind + normalised title already exists in the pass.
    func contains(kind: EntityKind, title: String) -> Bool {
        byKey["\(kind.rawValue)|\(MemoryText.normalizedTitle(title))"] != nil
    }

    /// Finalises the pass.
    func build() -> ExtractionResult {
        ExtractionResult(entities: entities, provenance: provenance)
    }
}
