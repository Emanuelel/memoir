import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// Owns every write into structured memory.
///
/// Extractors are pure: they read captures and propose entities. `MemoryService` is
/// the only thing that reconciles those proposals against what is already stored and
/// commits the result. Two laws are enforced here and nowhere else:
///
/// 1. **A user-corrected entity is never overwritten.** Confidence may rise; the title,
///    detail and due date the user set are permanent.
/// 2. **Nothing enters memory without provenance.** Every committed entity carries rows
///    pointing at the capture and the exact snippet it was derived from.
public actor MemoryService {

    private let store: Store
    private let extractors: [any Extractor]

    /// Creates a service over a store and an ordered list of extractors.
    ///
    /// Extractors run in order and each result is layered on top of the previous one
    /// with `ExtractionResult.merging(_:)`, so cheap deterministic passes should come
    /// first and model-backed passes last.
    /// Semantic search, used alongside keyword search so a paraphrase still finds things.
    private lazy var semantic = SemanticIndex(store: store)

    public init(store: Store, extractors: [any Extractor]) {
        self.store = store
        self.extractors = extractors
    }

    // MARK: - Consolidation

    /// Reads captures since a date, runs every extractor, and commits the reconciled
    /// result to the store.
    ///
    /// Running this twice over the same window is idempotent: entity IDs are derived
    /// from the normalised title and kind, so a second pass merges into the same rows
    /// instead of duplicating them.
    ///
    /// - Parameters:
    ///   - since: only captures at or after this date are considered.
    ///   - captureLimit: ceiling on how many captures one pass reads.
    ///   - now: the instant stamped on any entity this pass changes. Defaults to the wall
    ///     clock; integration tests inject a fixed date so a run is reproducible.
    /// - Returns: the number of entities created or changed.
    /// Phrases that only ever appear in Memoir's own answers.
    ///
    /// Cheap and deliberately literal: a substring match on text Memoir itself produces. It
    /// costs nothing and it stops the single worst feedback loop in the product.
    static let selfEchoMarkers: [String] = [
        "No model is running, so this comes straight from your local memory",
        "Answered straight from your records on this Mac",
        "Ask about your commitments, about today, or about a name or project",
        "Recently in play:",
        "Closest things I have to that:",
        "I do not have anything useful on that yet",
        "stayed on this Mac",
        "Ask Memoir about your work",
    ]

    static func isSelfEcho(_ text: String) -> Bool {
        selfEchoMarkers.contains { text.contains($0) }
    }

    /// Fingerprints of what Memoir has recently said, so it never re-learns its own output.
    /// The fixed marker list cannot catch a normal-looking answer like "You were on Google
    /// Chrome at 14:00…"; matching against the actual answer log does.
    /// Only a capture that POSTDATES an answer can be an echo of it.
    ///
    /// Fingerprints alone create a feedback loop that erases real memories. Memoir once
    /// correctly answered with a tweet's text; that answer entered the ask log, became a
    /// fingerprint, and from then on the ORIGINAL tweet was suppressed as "Memoir's own
    /// output", so answering a question once made it permanently unanswerable.
    ///
    /// A good answer quotes its source, so text alone cannot distinguish the two. Time can:
    /// the source existed before the answer did.
    static func isSelfEcho(_ capture: CaptureEvent, answers: [(text: String, at: Date)]) -> Bool {
        if isSelfEcho(capture.text) { return true }
        let hay = MemoryText.collapseWhitespace(capture.text).lowercased()
        for answer in answers where capture.ts > answer.at {
            let normalized = MemoryText.collapseWhitespace(answer.text).lowercased()
            guard normalized.count >= 40 else { continue }
            if hay.contains(String(normalized.prefix(60))) { return true }
        }
        return false
    }

    /// True when a capture is a conversation with an assistant rather than something seen.
    ///
    /// The second-order echo, and by far the more damaging one. ``isSelfEcho`` catches Memoir's
    /// OWN answers reappearing on screen. It cannot catch a conversation *about* those
    /// answers held in an assistant window, and those conversations quote the failures
    /// verbatim.
    ///
    /// Measured on the real corpus. Asked "what was I checking on lmuendeild last", the
    /// evidence section contained:
    ///
    ///     Claude: "...lmuendeild last? Answer: You were on **https://lmuendeild.ai**"
    ///     Claude: "Recall regressed: what url was the motion website → https://mem0ai/mem0"
    ///
    /// Those are bug reports. Memoir read them and served the documented WRONG answers back as
    /// fact, and every grounding guard passed, correctly, because the invented URL really
    /// was in the corpus by then. Debugging a memory in front of the memory teaches it the
    /// bugs.
    ///
    /// The rule is the one already applied to the semantic index: what you *asked* is not
    /// what you *saw*, and only the latter is evidence. Titles are still allowed through to
    /// the resumption timeline: "you were in Claude at 16:49" is true and useful. It is the
    /// BODY TEXT that may never be cited as fact.
    static func isMetaContent(_ capture: CaptureEvent) -> Bool {
        RuleExtractor.isConversationalAI(capture)
    }

    /// Adjacent pairs of content words from a question, in order.
    ///
    /// Stopwords are dropped first but adjacency is measured on the ORIGINAL sentence, so
    /// "the repo about screen memory" yields "screen memory" and not "repo screen": words
    /// separated by scaffolding were never side by side in the asker's mind either.
    static func contentBigrams(_ question: String, max: Int = 4) -> [String] {
        let words = question
            .split(whereSeparator: { !($0.isLetter || $0.isNumber) })
            .map { $0.lowercased() }
        var out: [String] = []
        for i in 0..<Swift.max(0, words.count - 1) {
            let a = words[i], b = words[i + 1]
            guard !SQLiteQueryText.stopWords.contains(a), !SQLiteQueryText.stopWords.contains(b),
                  a.count > 2, b.count > 2 else { continue }
            out.append("\(a) \(b)")
            if out.count >= max { break }
        }
        return out
    }

    /// Merges several ranked lists into one, using position rather than score.
    ///
    /// Keyword search returns BM25 scores; semantic search returns cosine similarities. The
    /// two are incomparable: a BM25 of 8.2 and a cosine of 0.41 have no common scale, and
    /// normalising them into one number would be a fiction dressed as arithmetic.
    ///
    /// Reciprocal rank fusion sidesteps that entirely by using only each item's *position*
    /// in each list, which is the one thing both searches genuinely express the same way.
    /// A capture that both searches rank highly beats one that only a single search loves,
    /// which is exactly the judgement we want and cannot get from either list alone.
    ///
    /// `k` damps the top of each list so first place is not overwhelming; 60 is the value
    /// from the original TREC work and behaves well here without tuning.
    static func reciprocalRankFusion(_ lists: [[CaptureEvent]], k: Double = 60) -> [CaptureEvent] {
        var score: [ID: Double] = [:]
        var byID: [ID: CaptureEvent] = [:]
        for list in lists {
            var rank = 0
            var seen = Set<ID>()
            for capture in list where seen.insert(capture.id).inserted {
                rank += 1
                score[capture.id, default: 0] += 1 / (k + Double(rank))
                byID[capture.id] = capture
            }
        }
        return score
            .sorted { a, b in
                // Ties broken by recency, so an otherwise equal pair reads newest first.
                a.value == b.value
                    ? (byID[a.key]?.ts ?? .distantPast) > (byID[b.key]?.ts ?? .distantPast)
                    : a.value > b.value
            }
            .compactMap { byID[$0.key] }
    }

    /// Recent answers with the time they were given, for ``isSelfEcho(_:answers:)``.
    static func recentAnswers(limit: Int = 60) -> [(text: String, at: Date)] {
        AskLog.shared.recent(limit: limit).flatMap { entry in
            [(entry.answer, entry.ts), (entry.question, entry.ts)]
        }
    }

    static func recentAnswerFingerprints(limit: Int = 60) -> [String] {
        AskLog.shared.recent(limit: limit).flatMap { entry -> [String] in
            // Both sides of the exchange leak onto the screen: Memoir's answer, and the
            // question the user typed into the ask bar (which is echoed in the app window).
            // Neither should ever be learned back as memory.
            [entry.answer, entry.question].compactMap { field in
                let normalized = MemoryText.collapseWhitespace(field)
                guard normalized.count >= 25 else { return nil }
                return String(normalized.prefix(50)).lowercased()
            }
        }
    }

    static func isSelfEcho(_ text: String, answerFingerprints: [String]) -> Bool {
        if isSelfEcho(text) { return true }
        guard !answerFingerprints.isEmpty else { return false }
        let hay = MemoryText.collapseWhitespace(text).lowercased()
        return answerFingerprints.contains { hay.contains($0) }
    }

    @discardableResult
    public func consolidate(since: Date, captureLimit: Int = 2_000, now: Date = Date()) async throws -> Int {
        let raw = try await store.captures(since: since, limit: captureLimit)
        guard !raw.isEmpty else { return 0 }

        // Memoir must never learn from its own output. Its answers appear on screen like any
        // other text, get captured, and come back as entities: the commitments list was
        // literally "Ask about your commitments, about today, or about a name or project
        // and I will", which is Memoir's own reply read back to itself. A memory that feeds
        // on its own exhaust degrades every answer that touches it.
        let fingerprints = Self.recentAnswerFingerprints()
        let captures = raw.filter { !Self.isSelfEcho($0.text, answerFingerprints: fingerprints) }
        guard !captures.isEmpty else { return 0 }

        var result = ExtractionResult.empty
        for extractor in extractors {
            do {
                let pass = try await extractor.extract(from: captures)
                result = result.merging(pass)
            } catch {
                // A failing extractor must never lose the work of the ones before it.
                Log.shared.warn("extractor failed, keeping earlier passes: \(error)")
            }
        }

        guard !result.isEmpty else { return 0 }
        return try await commit(result, now: now)
    }

    /// Reconciles an extraction result against stored state and writes it.
    ///
    /// - Parameters:
    ///   - result: the proposed entities and provenance.
    ///   - now: the instant stamped on any entity this call changes. Defaults to the wall
    ///     clock; integration tests inject a fixed date.
    /// - Returns: the number of entities created or materially changed.
    @discardableResult
    public func commit(_ result: ExtractionResult, now: Date = Date()) async throws -> Int {
        var touched = 0
        // Maps the extractor's proposed ID onto the ID that actually survived, so
        // provenance rows land on the right entity.
        var remap: [ID: ID] = [:]

        let existing = try await store.entities(kind: nil, includeDeleted: true)
        var byKey: [String: Entity] = [:]
        // Also index by ID. Extracted IDs are derived from the *original* title, so once
        // a user renames an entity the title lookup stops matching while the ID still
        // collides. Without this index the rename gets clobbered on the next pass.
        var byID: [ID: Entity] = [:]
        // And by alias, same kind only. This is what makes the ontology pay off: once the
        // vault says the project "Fenwick Migration" also goes by "fenwick", an extractor
        // seeing "fenwick" on screen corroborates the authored entity instead of creating
        // a duplicate guess beside it.
        var byAlias: [String: Entity] = [:]
        for e in existing {
            byKey[MemoryText.dedupeKey(kind: e.kind, title: e.title)] = e
            byID[e.id] = e
            for alias in e.aliases {
                byAlias[MemoryText.dedupeKey(kind: e.kind, title: alias)] = e
            }
        }

        // The stored entity a candidate should reconcile against, if any: exact title,
        // then either side's aliases, then raw ID collision.
        func storedMatch(for candidate: Entity, key: String) -> Entity? {
            if let hit = byKey[key] ?? byAlias[key] { return hit }
            for alias in candidate.aliases {
                let aliasKey = MemoryText.dedupeKey(kind: candidate.kind, title: alias)
                if let hit = byKey[aliasKey] ?? byAlias[aliasKey] { return hit }
            }
            return byID[candidate.id]
        }

        for candidate in result.entities {
            let key = MemoryText.dedupeKey(kind: candidate.kind, title: candidate.title)

            // Typing produces one capture per pause, each holding a longer prefix of the
            // same sentence, so exact-key dedup stored "LEt's explore some more creative
            // alternatives…" four times at four lengths. Match on prefix as well, and keep
            // whichever version is longest: that is the finished thought.
            var prefixMatch: Entity?
            if byKey[key] == nil, byID[candidate.id] == nil, candidate.title.count >= 25 {
                prefixMatch = byKey.values.first { existing in
                    existing.kind == candidate.kind
                        && RuleExtractor.isPrefixDuplicate(existing.title, candidate.title)
                }
                if let match = prefixMatch, candidate.title.count > match.title.count,
                   !match.corrected, match.source == .inferred, candidate.source == .inferred {
                    // The longer form supersedes the stub it grew from. Inferred over
                    // inferred only: an authored title is the user's own words and a
                    // longer on-screen variant of it is corroboration, not a correction.
                    var grown = match
                    grown.title = candidate.title
                    grown.updatedAt = now
                    try await store.upsert(entity: grown)
                    byKey[MemoryText.dedupeKey(kind: grown.kind, title: grown.title)] = grown
                    byID[grown.id] = grown
                    remap[candidate.id] = grown.id
                    touched += 1
                    continue
                }
                if prefixMatch != nil {
                    // Already have an equal or longer version; nothing to store.
                    remap[candidate.id] = prefixMatch!.id
                    continue
                }
            }

            guard let stored = storedMatch(for: candidate, key: key) else {
                try await store.upsert(entity: candidate)
                byKey[key] = candidate
                byID[candidate.id] = candidate
                for alias in candidate.aliases {
                    byAlias[MemoryText.dedupeKey(kind: candidate.kind, title: alias)] = candidate
                }
                remap[candidate.id] = candidate.id
                touched += 1
                continue
            }

            remap[candidate.id] = stored.id

            // A deleted entity stays deleted. Re-observing it must not resurrect it.
            // A deleted entity stays deleted, and a completed one stays completed.
            // Re-observing either must not resurrect it (CF-56).
            if stored.deleted || stored.completedAt != nil { continue }

            let (merged, changed) = MemoryMerge.merged(existing: stored, candidate: candidate, now: now)
            if changed {
                try await store.upsert(entity: merged)
                byKey[MemoryText.dedupeKey(kind: merged.kind, title: merged.title)] = merged
                byID[merged.id] = merged
                for alias in merged.aliases {
                    byAlias[MemoryText.dedupeKey(kind: merged.kind, title: alias)] = merged
                }
                touched += 1
            }
        }

        for row in result.provenance {
            guard let entityID = remap[row.entityID] else { continue }
            let mapped = Provenance(
                id: MemoryText.stableID("prov", entityID, row.captureID, row.field, row.snippet),
                entityID: entityID,
                captureID: row.captureID,
                field: row.field,
                snippet: row.snippet,
                ts: row.ts,
                // Rebuilt field by field, so the mask has to be copied explicitly. Forgetting it
                // here would drop attribution at the last step before the write, silently, and
                // in exactly the shape of the bug this column exists to expose.
                extractor: row.extractor
            )
            do {
                try await store.add(provenance: mapped)
            } catch {
                Log.shared.debug("provenance insert skipped: \(error)")
            }
        }

        return touched
    }

    // MARK: - Context

    /// Builds the packet handed to a brain for a given question.
    ///
    /// Selection order, highest priority first: pinned entities, commitments that are
    /// overdue or due soon, entities matching the question, then recent captures. The
    /// budget is a hard ceiling: the packet is truncated rather than allowed to exceed it.
    ///
    /// Every capture consulted is recorded in `captureIDs` so the answer can cite it.
    ///
    /// - Parameters:
    ///   - question: the user's question, used to rank relevance.
    ///   - budget: approximate token ceiling. Four characters are counted as one token, so
    ///     the rendered summary is never longer than `max(400, budget * 4)` characters,
    ///     separators and section headers included. `approxTokens` therefore never exceeds
    ///     `budget` for any budget of 100 tokens or more.
    ///   - now: the instant "recent" and "overdue" are measured against. Defaults to the
    ///     wall clock; integration tests inject a fixed date so the packet is reproducible.
    /// Damerau-Levenshtein distance, capped for speed.
    ///
    /// Handles the transposition case ("lmuendeild" for "lumenfield") that plain
    /// Levenshtein scores too harshly, which matters because transposed letters are the
    /// most common typo people actually make.
    static func editDistance(_ a: String, _ b: String, max limit: Int) -> Int {
        let x = Array(a), y = Array(b)
        if abs(x.count - y.count) > limit { return limit + 1 }
        var prev2 = [Int](), prev = Array(0...y.count)
        var current = [Int](repeating: 0, count: y.count + 1)
        for i in 1...max(x.count, 1) where !x.isEmpty {
            current[0] = i
            var best = i
            for j in 1...max(y.count, 1) where !y.isEmpty {
                let cost = x[i - 1] == y[j - 1] ? 0 : 1
                current[j] = Swift.min(current[j - 1] + 1, prev[j] + 1, prev[j - 1] + cost)
                if i > 1, j > 1, x[i - 1] == y[j - 2], x[i - 2] == y[j - 1] {
                    current[j] = Swift.min(current[j], prev2[j - 2] + cost)
                }
                best = Swift.min(best, current[j])
            }
            if best > limit { return limit + 1 }
            prev2 = prev; prev = current
        }
        return prev[y.count]
    }

    /// How many characters differ between two words when order is ignored.
    ///
    /// Catches the transposition-heavy typos that edit distance scores too harshly, which
    /// is most real typing: the fingers hit the right keys in the wrong order.
    static func letterBagDistance(_ a: String, _ b: String) -> Int {
        var counts: [Character: Int] = [:]
        for c in a { counts[c, default: 0] += 1 }
        for c in b { counts[c, default: 0] -= 1 }
        return counts.values.reduce(0) { $0 + abs($1) } / 2
    }

    /// Whether a word is ordinary English, and so should never be treated as a typo.
    ///
    /// Uses the system spell checker, which knows the whole language rather than just the
    /// handful of words this memory happens to have seen.
    static func isOrdinaryWord(_ word: String) -> Bool {
        #if canImport(AppKit)
        let range = NSRange(location: 0, length: (word as NSString).length)
        let misspelled = NSSpellChecker.shared.checkSpelling(of: word, startingAt: 0)
        // A word the checker cannot fault is a real word; leave it alone.
        return misspelled.location == NSNotFound || misspelled.location >= range.length
        #else
        return false
        #endif
    }

    /// Repairs a mistyped search term against words the memory has actually seen.
    ///
    /// Retrieval is exact-match FTS, so one transposed letter finds nothing: asked what
    /// was on "lmuendeild", Memoir retrieved no Lumenfield captures at all and the model
    /// filled the silence by inventing "https://lmuendeild.ai". Correcting the term before
    /// searching fixes the retrieval; the URL guard catches the invention if it does not.
    static func correct(term: String, against vocabulary: Set<String>) -> String? {
        let lower = term.lowercased()
        guard lower.count >= 5, !vocabulary.contains(lower) else { return nil }

        // Never "correct" an ordinary English word. The vocabulary is built from window
        // titles and entity names, so common verbs are simply absent from it, and that
        // absence was being read as evidence of a typo: "leave" (in "where did I leave
        // off") was rewritten to "real", which then searched for the wrong thing entirely.
        // A word only counts as mistyped if it is not a word.
        guard !Self.isOrdinaryWord(lower) else { return nil }
        // One edit per four characters, so long words tolerate more than short ones.
        let budget = Swift.max(1, lower.count / 4)
        var best: (word: String, distance: Int)?
        for candidate in vocabulary where abs(candidate.count - lower.count) <= budget {
            var d = editDistance(lower, candidate, max: budget)
            if d > budget {
                // Edit distance is unkind to scrambles. "lmuendeild" is four or five edits
                // from "lumenfield" but differs by a single LETTER as a multiset: people
                // transpose far more often than they substitute, so compare the bag of
                // characters too and take whichever measure is kinder.
                let bag = letterBagDistance(lower, candidate)
                if bag <= budget { d = bag } else { continue }
            }
            if best == nil || d < best!.distance { best = (candidate, d) }
        }
        return best?.word
    }

    /// Words the memory has actually seen: entity titles, app names and window titles.
    ///
    /// Deliberately small and cheap: a few hundred words rather than every token ever
    /// captured. Correcting against page body text would match noise.
    func searchVocabulary() async throws -> Set<String> {
        var words = Set<String>()
        for entity in try await store.entities(kind: nil, includeDeleted: false) {
            for word in MemoryText.normalizedTitle(entity.title).split(separator: " ")
            where word.count >= 4 {
                words.insert(String(word))
            }
        }
        for capture in try await store.captures(since: .distantPast, limit: 400) {
            words.insert(capture.appName.lowercased())
            guard let title = capture.windowTitle else { continue }
            for word in title.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            where word.count >= 4 {
                words.insert(String(word))
            }
        }
        return words
    }

    /// Human plural for a kind, used in both the populated and the empty case.
    static func pluralLabel(_ kind: EntityKind) -> String {
        switch kind {
        case .person: return "People"
        case .commitment: return "Commitments"
        case .project: return "Projects"
        case .decision: return "Decisions"
        case .thread: return "Threads"
        case .note: return "Notes"
        case .place: return "Places"
        }
    }

    /// Detects a question about a whole category of entity rather than a keyword.
    /// True when the question is asking how long something took.
    ///
    /// Durations are arithmetic over the sessions table, not something to be inferred from
    /// context. Asked how long Chrome had been open the model answered "1 hour and 19
    /// minutes" against a real figure of 37, and the grounding guard passed it, because
    /// "19" appears all over the context as a timestamp. The fix is not a better guard;
    /// it is to compute the number and hand it over already worked out.
    static func asksAboutDuration(_ question: String) -> Bool {
        let q = question.lowercased()
        let cues = ["how much time", "how long", "time spent", "time did i spend",
                    "hours", "minutes", "time in "]
        return cues.contains(where: q.contains)
    }

    /// How far back a "where was I" question is asking about, if it is one.
    ///
    /// Resumption questions carry almost no keywords ("where did I leave off" has nothing
    /// to search FOR), so running them through keyword retrieval returned whatever happened
    /// to match, and answers came back hours stale. What they actually want is a timeline:
    /// the most recent activity, grouped, in order. Returns nil for every other question.
    /// - Parameter force: when the router has already classified this as resumption, a
    ///   timeline is wanted even if the wording carries no recognisable cue: "and chrome?"
    ///   as a follow-up has no keywords at all but is plainly a resumption question.
    static func resumptionWindow(
        _ question: String,
        now: Date,
        force: Bool = false
    ) -> (since: Date, until: Date?, label: String)? {
        let q = question.lowercased()
        let calendar = Calendar.current
        let todayStart = calendar.startOfDay(for: now)

        // Explicit windows first, so "an hour ago" is not swallowed by the generic case.
        // "Yesterday" carries an upper bound: `(startOfDay(now), "yesterday")` was the
        // original bug (TODAY's start, labelled yesterday), so "what was I doing
        // yesterday" rendered today's spans under yesterday's name.
        if q.contains("yesterday"),
           let yesterdayStart = calendar.date(byAdding: .day, value: -1, to: todayStart) {
            return (yesterdayStart, todayStart, "yesterday")
        }
        let windows: [(needles: [String], seconds: Double, label: String)] = [
            (["an hour ago", "1 hour ago", "hour ago"], 5_400, "the last hour or so"),
            (["this morning", "before lunch"], 0, "this morning"),
            (["this afternoon"], 0, "this afternoon"),
            (["last 3 h", "last three hours", "last 3h"], 10_800, "the last three hours"),
            (["today"], 0, "today"),
        ]
        for w in windows where w.needles.contains(where: q.contains) {
            if w.seconds > 0 { return (now.addingTimeInterval(-w.seconds), nil, w.label) }
            return (todayStart, nil, w.label)
        }

        let resumption = [
            "where did i leave off", "where was i", "leave off", "left off",
            "catch me up", "what was i doing", "what was i working on",
            "what have i been doing", "pick up where", "resume", "get me back",
            "most recently", "last thing", "just now", "before i stopped",
        ]
        guard force || resumption.contains(where: q.contains) else { return nil }
        return (now.addingTimeInterval(-4 * 3_600), nil, "the last few hours")
    }

    static func askedAboutKind(_ question: String) -> EntityKind? {
        let q = question.lowercased()
        if q.contains("project") { return .project }
        if q.contains("who ") || q.contains("people") || q.contains("person") { return .person }
        if q.contains("commitment") || q.contains("owe") || q.contains("promised")
            || q.contains("due") || q.contains("deadline") { return .commitment }
        if q.contains("decision") || q.contains("decided") { return .decision }
        if q.contains("note") { return .note }
        return nil
    }

    /// Collapses near-identical captures of the same window to a single key.
    ///
    /// Storage dedupes only against the immediately previous capture, so alternating
    /// between two windows defeats it and both get stored many times over. The context
    /// packet cannot afford to repeat them.
    static func dedupeKey(_ capture: CaptureEvent) -> String {
        let head = MemoryText.collapseWhitespace(capture.text)
            .lowercased()
            .prefix(120)
        return capture.appBundleID + "|" + head
    }

    /// Builds the context packet for a question.
    ///
    /// - Parameter category: what kind of question this is, decided upstream by
    ///   ``QuestionRouter``. When nil the builder falls back to its own keyword matching,
    ///   which is what every caller did before routing existed and what the MCP server
    ///   still does.
    ///
    ///   Passing it matters: the sections below used to be gated by three independent
    ///   keyword matchers that could all fire, or none, for the same question. A routed
    ///   category means an accounting question gets durations and nothing else, a
    ///   resumption question gets the timeline and nothing else, and an out-of-scope
    ///   question builds no context at all rather than assembling 2000 tokens on its way
    ///   to refusing.
    public func context(
        for question: String,
        budget: Int,
        now: Date = Date(),
        category: QuestionCategory? = nil
    ) async throws -> ContextPacket {
        // Nothing to retrieve. Answering happens without a memory lookup at all.
        if category == .smallTalk || category == .outOfScope { return .empty }

        let charBudget = max(400, budget * 4)
        let echoAnswers = Self.recentAnswers()
        var sections: [String] = []
        var usedChars = 0
        var entityIDs: [ID] = []
        var captureIDs: [ID] = []
        var timer = StageTimer()

        // The rendered summary is `sections.joined(separator: "\n\n")`, so a section costs
        // its own length plus the two characters that join it to the previous one. Charging
        // anything less lets the packet overrun the ceiling it promises to respect: the
        // separator and the "Recent activity:" header used to be free, which pushed a
        // 1 000-token request to 4 007 characters: 1 001 tokens.
        func joinedCost(_ length: Int) -> Int {
            length + (sections.isEmpty ? 0 : 2)
        }

        func append(_ block: String) -> Bool {
            let cost = joinedCost(block.count)
            guard usedChars + cost <= charBudget else { return false }
            sections.append(block)
            usedChars += cost
            return true
        }

        let all = try await store.entities(kind: nil, includeDeleted: false)
        let askedKind = Self.askedAboutKind(question)

        // Durations, computed rather than inferred.
        if category == .accounting || (category == nil && Self.asksAboutDuration(question)) {
            let dayStart = Calendar.current.startOfDay(for: now)
            let sessions = try await store.sessions(from: dayStart, to: now)
            var byApp: [String: TimeInterval] = [:]
            for session in sessions where !session.idle {
                byApp[session.appName, default: 0] += session.duration
            }
            func durationText(_ seconds: TimeInterval) -> String {
                let minutes = Int(seconds / 60)
                return minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes) min"
            }
            if !byApp.isEmpty {
                let lines = byApp.sorted { $0.value > $1.value }.prefix(10).map { app, seconds in
                    "- \(app): \(durationText(seconds))"
                }
                _ = append("Time today, measured from session records. Use these figures exactly and never estimate your own:\n"
                    + lines.joined(separator: "\n"))
            }
            // The same time cut by project, when the ontology recognised any. This is
            // what lets a model answer "how long on the migration" instead of only
            // "how long in Xcode", and because the guard checks figures against this
            // summary, computed project durations MUST appear here to be sayable.
            let spans = try await workSpans(from: dayStart, to: now)
            var byLabel: [String: (seconds: TimeInterval, apps: [String])] = [:]
            for span in spans where span.entityID != nil {
                var entry = byLabel[span.label] ?? (0, [])
                entry.seconds += span.seconds
                for app in span.apps where !entry.apps.contains(app) { entry.apps.append(app) }
                byLabel[span.label] = entry
            }
            if !byLabel.isEmpty {
                let lines = byLabel.sorted { $0.value.seconds > $1.value.seconds }.prefix(8)
                    .map { label, entry in
                        "- \(label): \(durationText(entry.seconds)) (\(entry.apps.joined(separator: ", ")))"
                    }
                _ = append("Time today by project, computed from the same records:\n"
                    + lines.joined(separator: "\n"))
            }
        }


        // Resumption: a timeline, not a search.
        let wantsTimeline = category == .resumption || category == nil
        if wantsTimeline, let window = Self.resumptionWindow(question, now: now, force: category == .resumption) {
            let windowEnd = window.until ?? now
            // Grouped spans lead: "40 min on the migration across three apps" answers
            // "where was I" better than eighteen interleaved window titles ever did.
            // The flat timeline below stays for the detail.
            if category == .resumption {
                let spans = try await workSpans(from: window.since, to: windowEnd)
                if !spans.isEmpty {
                    let fmt = DateFormatter()
                    fmt.dateFormat = "HH:mm"
                    let lines = spans.suffix(8).reversed().map { span -> String in
                        let minutes = Int(span.seconds / 60)
                        let dur = minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes) min"
                        let apps = WorkSpanBuilder.appsWorthNaming(span)
                        let where_ = apps.isEmpty ? "" : " (\(apps.joined(separator: ", ")))"
                        return "- until \(fmt.string(from: span.end)): \(span.label), \(dur)\(where_)"
                    }
                    if append("Work in \(window.label), grouped, most recent first:\n" + lines.joined(separator: "\n")) {
                        for span in spans.suffix(8) { captureIDs.append(contentsOf: span.captureIDs.suffix(1)) }
                    }
                }
            }
            let recent = try await store.captures(from: window.since, to: windowEnd, limit: 600)
            if !recent.isEmpty {
                var lines: [String] = []
                var seen = Set<String>()
                var ids: [ID] = []
                let fmt = DateFormatter()
                fmt.dateFormat = "HH:mm"
                // Newest first, one line per distinct thing, so a long stretch in one
                // window does not crowd out everything either side of it.
                for capture in recent.sorted(by: { $0.ts > $1.ts }) {
                    if Self.isSelfEcho(capture, answers: echoAnswers) { continue }
                    let title = capture.windowTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
                    let subject = (title?.isEmpty == false)
                        ? title!
                        : MemoryText.truncate(MemoryText.collapseWhitespace(capture.text), max: 90)
                    // An entry whose subject is just the app's own name carries nothing:
                    // "Claude: Claude" is not a memory. These dominated the timeline purely
                    // by being newest, and the model answered with them instead of the real
                    // pages sitting underneath.
                    let normalized = subject.lowercased()
                    let appLower = capture.appName.lowercased()
                    guard normalized != appLower,
                          !normalized.hasPrefix(appLower + " "),
                          subject.count >= 6 else { continue }

                    let key = capture.appBundleID + "|" + normalized
                    guard seen.insert(key).inserted else { continue }
                    lines.append("- \(fmt.string(from: capture.ts)) \(capture.appName): \(subject)")
                    ids.append(capture.id)
                    if lines.count >= 18 { break }
                }
                if !lines.isEmpty {
                    let header = "What you were doing in \(window.label), most recent first:"
                    if append(header + "\n" + lines.joined(separator: "\n")) {
                        captureIDs.append(contentsOf: ids)
                    }
                }
            }
        }


        // 3a. Whole-category questions.
        //
        // "what projects am I working on" is a question about a KIND, not about keywords.
        // Searching entity titles for "projects" matches nothing, so the packet used to
        // carry no projects at all and the model answered from whatever captures happened
        // to be nearby, once inventing projects out of a Finder file listing.
        if let kind = askedKind {
            // Completed commitments are done, not "commitments I have seen".
            let ofKind = all.filter { $0.kind == kind && !$0.deleted && ($0.kind != .commitment || $0.completedAt == nil) }
                .sorted { $0.confidence > $1.confidence }
            if ofKind.isEmpty {
                // EXPLICIT NEGATIVE. Omitting an empty section silently is what produced
                // "You owe someone $100" with no commitments on record, and "You talked
                // to Tempolog" (a product page named as a person) with no people on
                // record: given no evidence and no statement that there is none, a small
                // model fills the gap. Saying "none recorded" out loud is the difference
                // between an honest answer and an invented one.
                _ = append("\(Self.pluralLabel(kind)): none recorded. I have nothing on this. Say so rather than guessing.")
            } else {
                let lines = ofKind.prefix(25).map { e -> String in
                    let detail = e.detail.map { " (\(MemoryText.truncate($0, max: 80)))" } ?? ""
                    return "- \(e.title)\(detail)"
                }
                let header = "\(Self.pluralLabel(kind)) I have seen:"
                if append(header + "\n" + lines.joined(separator: "\n")) {
                    entityIDs.append(contentsOf: ofKind.prefix(25).map(\.id))
                }
            }
        }


        // 1. Pinned.
        let pinned = all.filter(\.pinned)
        if !pinned.isEmpty {
            let lines = pinned.prefix(12).map { "- [\($0.kind.rawValue)] \($0.title)" }
            if append("Pinned:\n" + lines.joined(separator: "\n")) {
                entityIDs.append(contentsOf: pinned.prefix(12).map(\.id))
            }
        }

        // 2. Commitments, overdue first. Completed ones are done, never context.
        let commitments = all
            .filter { $0.kind == .commitment && $0.completedAt == nil && !$0.provisional }
            .sorted { (a, b) in
                switch (a.dueAt, b.dueAt) {
                case let (x?, y?): return x < y
                case (_?, nil): return true
                case (nil, _?): return false
                case (nil, nil): return a.updatedAt > b.updatedAt
                }
            }
        // Commitments lead only when they were asked for. On a recall question they are
        // noise that crowds the actual answer out of the budget: a search for a tweet came
        // back with six commitments and no tweet, purely because they are rendered first.
        //
        // The second clause is why "any to do list ?" was answered "There is no to-do list
        // visible on the screen" while nine commitments sat in the database. Commitment
        // questions are routed to `.recall` (they are lookups, and `.outOfScope` was worse),
        // and this gate then read `.recall` as "not a commitments question" and left them
        // out of their own answer. Asking for them explicitly has to beat the category.
        let commitmentsWanted = (askedKind == .commitment)
            || QuestionRouter.asksAboutCommitments(question)
            || (askedKind == nil && category != .recall && category != .resumption)
        if !commitments.isEmpty, commitmentsWanted {
            let fmt = ISO8601DateFormatter()
            fmt.formatOptions = [.withFullDate]
            let lines = commitments.prefix(12).map { e -> String in
                guard let due = e.dueAt else { return "- \(e.title)" }
                let overdue = due < now ? " (OVERDUE)" : ""
                return "- \(e.title), due \(fmt.string(from: due))\(overdue)"
            }
            if append("Open commitments:\n" + lines.joined(separator: "\n")) {
                entityIDs.append(contentsOf: commitments.prefix(12).map(\.id))
            }
        }

        // 3. Entities matching the question.
        var terms = MemoryText.keywords(question, limit: 6)
        // Hoisted out of the block below so 3b can search the capture stream for the names
        // these entities go by. That is the whole of entity-linked retrieval: resolve the
        // question to things first, then look for the things rather than for the words.
        var questionEntities: [Entity] = []
        if !terms.isEmpty {
            var matches: [Entity] = []
            var seen = Set(entityIDs)
            for term in terms {
                let hits = (try? await store.searchEntities(term, limit: 10)) ?? []
                for hit in hits where !hit.deleted && seen.insert(hit.id).inserted {
                    matches.append(hit)
                }
                // An alias is invisible to the full-text index: it lives in a JSON column
                // no trigger feeds. Without this, a memory that knows `PLAT` is the Fenwick
                // migration still answers "what's happening with PLAT" with nothing.
                //
                // A table scan per term, and deliberately: entities number in the hundreds
                // where captures number in the tens of thousands, so this is the cheap half
                // of the search. Revisit if a memory ever holds enough entities to notice.
                let named = (try? await store.entitiesNamed(term, limit: 5)) ?? []
                for hit in named where !hit.deleted && seen.insert(hit.id).inserted {
                    matches.append(hit)
                }
            }
            // Relevance and recency together, so a project last touched in the spring stops
            // arriving ahead of the one that was on screen this morning. Anything authored,
            // corrected or pinned is exempt: see `MemoryRank.recencyWeight(for:now:)`.
            matches = MemoryRank.byRelevanceAndRecency(matches, now: now)
            questionEntities = matches
            if !matches.isEmpty {
                let lines = matches.prefix(15).map { e -> String in
                    let detail = e.detail.map { ": " + MemoryText.truncate($0, max: 160) } ?? ""
                    return "- [\(e.kind.rawValue)] \(e.title)\(detail)"
                }
                if append("Related to your question:\n" + lines.joined(separator: "\n")) {
                    entityIDs.append(contentsOf: matches.prefix(15).map(\.id))
                }
            }
        }

        // 3b. Captures that actually match the question.
        //
        // Without this the packet was pure reverse-chronological recency, so any question
        // about something older than the last dozen captures was unanswerable no matter
        // how much context was spent: the model was asked about a page it had never been
        // shown and correctly said it did not know. Relevance goes BEFORE recency.
        var shownKeys = Set<String>()
        // Repair mistyped terms against words the memory has actually seen, so one
        // transposed letter does not silently return nothing.
        if !terms.isEmpty {
            let vocabulary = try await searchVocabulary()
            terms = terms.map { term in
                guard let fixed = Self.correct(term: term, against: vocabulary) else { return term }
                Log.shared.debug("search term '\(term)' corrected to '\(fixed)'")
                return fixed
            }
        }
        if !terms.isEmpty {
            var hits: [CaptureEvent] = []
            var seenIDs = Set<ID>()
            // Search the WHOLE question once, not each keyword separately.
            //
            // Per-term searching threw away the thing that makes ranking work: BM25 scores
            // a capture by how many query terms it contains and how rare they are, so the
            // tweet matching five terms should beat a page matching one. Searching term by
            // term ranked within each term in isolation, so a page that merely says "app"
            // arrived ahead of the post that said "claude skills wrapped sms app".
            timer.mark("pre")
            let combined = (try? await store.searchCaptures(question, limit: 30)) ?? []
            timer.mark("fts.whole")
            var perTerm: [CaptureEvent] = []
            for term in terms {
                perTerm.append(contentsOf: (try? await store.searchCaptures(term, limit: 8)) ?? [])
            }
            timer.mark("fts.perTerm")

            // Meaning, after words. Keyword search is exact and cheap, and it fails on the
            // one thing a memory is asked for most: a half-remembered paraphrase.
            //
            // "What was that repo about screen memory" is the case. BM25 scores mem0
            // ("Universal memory layer for AI Agents") above Afterglance, because the literal
            // word "memory" is in one title and not the other, while the repo the question
            // describes is the one that records your screen.
            var semanticHits: [CaptureEvent] = []
            if let scored = try? await semantic.search(question, limit: 12) {
                for hit in scored {
                    if let capture = try? await store.capture(id: hit.id) {
                        semanticHits.append(capture)
                    }
                }
            }
            timer.mark("semantic")

            // Merge the two rankings by RANK, never by score.
            //
            // Appending semantic hits after keyword hits was not enough: the right page was
            // present but buried below the wrong one, and the model reads top-down, so it
            // answered "mem0ai/mem0" 3 times in 5 with Afterglance sitting at position 11.
            // Presence in the packet is not the same as prominence in it.
            //
            // BM25 scores and cosine similarities are incomparable quantities, so blending
            // them would be a fiction dressed as arithmetic. Reciprocal rank fusion uses only
            // the position within each list, which is the one thing the two searches DO
            // express on the same scale: a page both searches rank highly beats a page that
            // only one of them loves.
            // Exact phrases, the strongest signal of the three.
            //
            // Two words the asker put side by side belong together; the same two words
            // scattered across a page do not. "screen memory" is verbatim in the Afterglance
            // page and nowhere in mem0's, which is precisely the distinction neither BM25 nor
            // cosine could draw on its own.
            var phraseHits: [CaptureEvent] = []
            for phrase in Self.contentBigrams(question) {
                phraseHits.append(contentsOf: (try? await store.searchCapturesPhrase(phrase, limit: 6)) ?? [])
            }
            timer.mark("fts.phrase")

            // Entity-linked hits: the names the memory knows this question is ABOUT, which
            // are not always the names the question used.
            //
            // The case this exists for: the vault says the project is "Fenwick Migration"
            // with alias "PLAT", every commit and ticket on screen says "PLAT-42", and the
            // question says "how's fenwick going". BM25 cannot bridge that ("fenwick" is
            // not in the captures, and "PLAT" is not in the question), and cosine cannot
            // either, because `PLAT-42` carries no sentence meaning to be similar to. Only
            // the ontology holds both ends of the rename, so only it can produce this list.
            //
            // It is one list among five rather than an override. An alias is a strong hint
            // about what is being discussed and a weak one about which capture answers the
            // question, and reciprocal rank fusion is exactly the tool for a signal that is
            // confident about the subject and agnostic about the row.
            var entityHits: [CaptureEvent] = []
            for name in MemoryRank.linkedNames(for: questionEntities, question: question) {
                entityHits.append(contentsOf: (try? await store.searchCaptures(name, limit: 6)) ?? [])
            }
            timer.mark("fts.entity")

            let fused = Self.reciprocalRankFusion([phraseHits, combined, perTerm, semanticHits, entityHits])

            for capture in fused where seenIDs.insert(capture.id).inserted {
                    if Self.isSelfEcho(capture, answers: echoAnswers) { continue }
                    // Never cite a conversation with an assistant as evidence of fact.
                    if Self.isMetaContent(capture) { continue }
                    // Near-duplicate suppression: the same page captured repeatedly differs
                    // only in trailing chrome, so key on the normalised head of the text.
                    let key = Self.dedupeKey(capture)
                    guard shownKeys.insert(key).inserted else { continue }
                    hits.append(capture)
            }
            if !hits.isEmpty {
                let fmt = DateFormatter()
                fmt.dateFormat = "EEE HH:mm"
                // Keep relevance order. `hits` already arrives BM25-ranked, best first;
                // re-sorting by timestamp here discarded that a second time, after the SQL
                // had just been fixed to preserve it. Recency is the right order for a
                // timeline, and the wrong one for "find me that thing".
                let lines = hits.prefix(12).map { c -> String in
                    let title = c.windowTitle.map { " (\($0))" } ?? ""
                    let snippet = MemoryText.truncate(MemoryText.collapseWhitespace(c.text), max: 300)
                    return "- \(fmt.string(from: c.ts)) \(c.appName)\(title): \(snippet)"
                }
                if append("Matching what you asked about:\n" + lines.joined(separator: "\n")) {
                    captureIDs.append(contentsOf: hits.prefix(12).map(\.id))
                }
            }
        }

        // 4. Recent captures, most recent first, whatever budget remains.
        let recent = try await store.captures(since: now.addingTimeInterval(-60 * 60 * 12), limit: 120)
        let header = "Recent activity:"
        if !recent.isEmpty, usedChars + joinedCost(header.count) <= charBudget {
            var lines: [String] = []
            var ids: [ID] = []
            // Charged up front, then grown line by line, and only spent once the section is
            // actually appended. Nothing is counted that does not end up in the summary.
            var sectionCost = joinedCost(header.count)
            let fmt = DateFormatter()
            fmt.dateFormat = "HH:mm"
            for capture in recent.sorted(by: { $0.ts > $1.ts }) {
                if Self.isSelfEcho(capture, answers: echoAnswers) { continue }
                // This section quotes body text, so the same rule applies as for search hits.
                if Self.isMetaContent(capture) { continue }
                let snippet = MemoryText.truncate(MemoryText.collapseWhitespace(capture.text), max: 220)
                guard !snippet.isEmpty else { continue }
                // The same window captured over and over used to fill the packet: one page
                // appeared eight times and crowded out everything else.
                guard shownKeys.insert(Self.dedupeKey(capture)).inserted else { continue }
                let line = "- \(fmt.string(from: capture.ts)) \(capture.appName): \(snippet)"
                // +1 for the newline that joins this line to the one before it.
                if usedChars + sectionCost + line.count + 1 > charBudget { break }
                lines.append(line)
                ids.append(capture.id)
                sectionCost += line.count + 1
            }
            if !lines.isEmpty {
                sections.append(header + "\n" + lines.joined(separator: "\n"))
                usedChars += sectionCost
                captureIDs.append(contentsOf: ids)
            }
        }

        timer.mark("assemble")
        timer.report()
        let summary = sections.joined(separator: "\n\n")
        return ContextPacket(
            summary: summary,
            captureIDs: captureIDs,
            entityIDs: entityIDs,
            approxTokens: summary.count / 4
        )
    }

    /// Re-runs today's extraction guards over entities extracted before they existed.
    ///
    /// A guard only ever protects what has not been written yet. The three junk rows that
    /// motivated the guards were still sitting in the live memory afterwards, still presented
    /// as things the user owed:
    ///
    ///     "mikkel torres @0xquillvox follow i will tell my kids that arden built this in a
    ///      cave with a box of scraps 5/30/26, 8:01 PM 28"    - due 2026-05-30, OVERDUE
    ///
    /// A stranger's tweet, scraped off a timeline and shown as the user's obligation with a
    /// deadline. Inventing a debt is the worst class of false memory, and fixing the extractor
    /// without sweeping up behind it leaves the visible damage in place.
    ///
    /// Soft delete, never hard: if a guard is wrong the row is recoverable, and CF-20 already
    /// promises entities outlive their captures.
    ///
    /// **Authored entities are never touched.** The guards exist to judge guesses, and
    /// something the user typed is not a guess.
    ///
    /// - Returns: how many entities were retired.
    @discardableResult
    public func sweepJunk(dryRun: Bool = false) async throws -> [Entity] {
        let all = try await store.entities(kind: nil, includeDeleted: false)
        var retired: [Entity] = []
        for entity in all {
            // Never judge what the user authored.
            guard entity.source == .inferred else { continue }
            guard RuleExtractor.isJunkEntity(entity) else { continue }
            retired.append(entity)
            if !dryRun { try await store.deleteEntity(id: entity.id) }
        }
        if !retired.isEmpty {
            Log.shared.info("swept \(retired.count) junk entities\(dryRun ? " (dry run)" : "")")
        }
        return retired
    }

    /// Retires people whose every sighting was on somebody else's feed.
    ///
    /// The guard that stops these being written lives in the extractor, and a guard only
    /// ever protects what has not been written yet, the lesson this codebase has now
    /// recorded three times. On the database that motivated it, "Jorge Martín" was a person
    /// at 99% confidence with twelve mentions, every one of them X's trending sidebar.
    ///
    /// Deleted rather than demoted, unlike a commitment: a commitment read off a page is
    /// still a real sentence the user may recognise, while a name the timeline promoted is
    /// nothing to them at all. Soft delete, so a wrong call is recoverable.
    ///
    /// Asks the on-device model which of the remaining "people" are people.
    ///
    /// The pass that runs after the rules have done all they can. On the database this was
    /// written for, the heuristics removed 241 of 262 names honestly and left behind a
    /// residue (`Claude Code`, `Apple Silicon`, `Dynamic Island`) that no property of the
    /// data distinguishes from `Elena Duarte`. See ``PersonJudge`` for why that is a language
    /// question rather than a query.
    ///
    /// Conservative in the same three ways as every other sweep here: never touches what the
    /// user authored, corrected or pinned; keeps anything the model is unsure about; and does
    /// nothing at all when the model is unavailable. The delete is the store's soft delete, so
    /// the row and its provenance stay on disk and only "forget everything" removes bytes.
    ///
    /// - Parameters:
    ///   - limit: how many to judge in one pass. Each judgement is a model call of a second or
    ///     two, so this is deliberately bounded rather than run over hundreds of names at once.
    ///   - dryRun: report without changing anything.
    /// - Returns: the entities judged not to be people.
    @discardableResult
    public func judgeUncertainPeople(
        limit: Int = 40,
        dryRun: Bool = false,
        judge: PersonJudge = PersonJudge()
    ) async throws -> [(entity: Entity, verdict: PersonJudge.Verdict)] {
        guard PersonJudge.isAvailable() else { return [] }

        let people = try await store.entities(kind: .person, includeDeleted: false)
        var out: [(Entity, PersonJudge.Verdict)] = []
        var judged = 0

        for person in people {
            guard judged < limit else { break }
            guard person.source == .inferred, !person.corrected, !person.pinned else { continue }

            // The windows it was seen on are the deciding context, so a candidate with no
            // surviving captures is not worth asking about.
            let rows = try await store.provenance(entityID: person.id)
            var titles: [String] = []
            for row in rows.prefix(24) {
                if let capture = try await store.capture(id: row.captureID),
                   let title = capture.windowTitle, !title.isEmpty,
                   !titles.contains(title) {
                    titles.append(title)
                }
            }
            guard !titles.isEmpty else { continue }

            judged += 1
            let verdict = await judge.judge(
                PersonJudge.Candidate(id: person.id, name: person.title, seenOn: titles)
            )
            guard verdict == .notAPerson else { continue }

            out.append((person, verdict))
            if !dryRun {
                try await store.deleteEntity(id: person.id)
                Log.shared.info("retired \"\(person.title)\": the model judged it not a person")
            }
        }
        return out
    }

    /// **Never touches what the user authored or corrected**, and never a person with any
    /// sighting somewhere else: one message, one email header, one mention in a document
    /// and they are somebody the user actually deals with.
    ///
    /// - Returns: the people that were retired.
    @discardableResult
    public func retireFeedOnlyPeople(dryRun: Bool = false) async throws -> [Entity] {
        let people = try await store.entities(kind: .person, includeDeleted: false)
        var retired: [Entity] = []
        for person in people {
            guard person.source == .inferred, !person.corrected, !person.pinned else { continue }
            let rows = try await store.provenance(entityID: person.id)
            guard !rows.isEmpty else { continue }

            var everySightingIsAFeed = true
            for row in rows {
                guard let capture = try await store.capture(id: row.captureID) else {
                    // The capture rolled off, so its surface is unknowable. Silence is not
                    // evidence of a feed: leave the row alone.
                    everySightingIsAFeed = false
                    break
                }
                // Feeds and results pages both. The first version only knew about feeds and
                // retired nothing at all from a database where 254 of 260 people had been
                // read off search results and business directories.
                let disposable = RuleExtractor.isSocialFeed(capture)
                    || RuleExtractor.isSearchResults(capture)
                if !disposable { everySightingIsAFeed = false; break }
            }
            guard everySightingIsAFeed else { continue }

            retired.append(person)
            if !dryRun { try await store.deleteEntity(id: person.id) }
        }
        if !retired.isEmpty {
            Log.shared.info("retired \(retired.count) feed-only people\(dryRun ? " (dry run)" : "")")
        }
        return retired
    }

    /// Marks already-stored commitments provisional when every scrap of evidence for them
    /// came off a page the user was reading.
    ///
    /// The guard that stops this happening lives in the extractor, and a guard only ever
    /// protects what has not been written yet. On the database that motivated it, 17 of 25
    /// stored commitments were somebody else's first-person sentences (a tweet, a
    /// LinkedIn reply, an AI-drafted email, the user's own landing-page copy), every one
    /// presented as something they owed. Fixing the extractor without sweeping up behind
    /// it leaves the visible damage in place.
    ///
    /// Demoted, never deleted: the text is real and the user may recognise it. And never
    /// touched if any provenance points somewhere they actually write, or if the row is
    /// authored or corrected: a promise the user typed is theirs whatever else was on
    /// screen at the time.
    ///
    /// - Returns: the commitments that were demoted.
    @discardableResult
    public func demoteUnownedCommitments(dryRun: Bool = false) async throws -> [Entity] {
        let commitments = try await store.entities(kind: .commitment, includeDeleted: false)
        var demoted: [Entity] = []
        for entity in commitments {
            guard !entity.provisional, !entity.corrected, entity.source == .inferred else { continue }
            let rows = try await store.provenance(entityID: entity.id)
            guard !rows.isEmpty else { continue }

            var sawReadingSurface = false
            var sawSomewhereElse = false
            for row in rows {
                guard let capture = try await store.capture(id: row.captureID) else {
                    // The capture rolled off, so its surface is unknowable. Silence is not
                    // evidence of reading: leave the row alone.
                    sawSomewhereElse = true
                    continue
                }
                if RuleExtractor.isReadingSurface(capture) { sawReadingSurface = true }
                else { sawSomewhereElse = true }
            }
            guard sawReadingSurface, !sawSomewhereElse else { continue }

            var updated = entity
            updated.provisional = true
            demoted.append(updated)
            if !dryRun { try await store.upsert(entity: updated) }
        }
        if !demoted.isEmpty {
            Log.shared.info("demoted \(demoted.count) unowned commitments\(dryRun ? " (dry run)" : "")")
        }
        return demoted
    }

    /// Stage timings for the context build, printed when MEMOIR_TIMING is set.
    ///
    /// Added because the first three guesses about where 7 seconds went were all wrong. The
    /// project's own rule applies to performance as much as to bugs: instrument the decision,
    /// do not reason about the result.
    struct StageTimer {
        private let enabled = ProcessInfo.processInfo.environment["MEMOIR_TIMING"] != nil
        private var last = Date()
        private var marks: [(String, Double)] = []

        mutating func mark(_ name: String) {
            guard enabled else { return }
            let now = Date()
            marks.append((name, now.timeIntervalSince(last) * 1000))
            last = now
        }

        func report() {
            guard enabled, !marks.isEmpty else { return }
            let total = marks.reduce(0) { $0 + $1.1 }
            let line = marks
                .sorted { $0.1 > $1.1 }
                .map { "\($0.0) \(Int($0.1))ms" }
                .joined(separator: "  ")
            FileHandle.standardError.write(Data("[timing] total \(Int(total))ms  \(line)\n".utf8))
        }
    }

    // MARK: - PUSH: what the user tells Memoir

    /// Parses a phrase into a proposed entity **without writing anything**.
    ///
    /// CF-51. The separation between this and ``commitPush(_:now:)`` is the whole safety
    /// property: a mis-heard sentence must be visible and rejectable before it becomes a
    /// memory. Everything Memoir inferred up to now could be wrong and correctable; something
    /// it wrote because it misunderstood you is wrong and *authoritative*, which is worse.
    ///
    /// - Returns: the proposal to show the user, or nil when the phrase was not usable.
    ///   Nil must be surfaced honestly, never silently dropped: the user said something.
    public nonisolated func previewPush(_ phrase: String, now: Date = Date()) -> PushIntent? {
        PushParser.parse(phrase, reference: now)
    }

    /// Commits a push the user has explicitly accepted.
    ///
    /// Idempotent by construction: the id is derived from the kind and the normalised title,
    /// so accepting the same proposal twice updates one row rather than making two. That
    /// matters because "did my Enter register?" is a question people answer by pressing Enter
    /// again.
    ///
    /// The entity is written `.authored` with full confidence. It carries no provenance,
    /// deliberately: provenance points at the capture a claim was inferred from, and there is
    /// no capture here. The user is the source, which is exactly what `.authored` records.
    @discardableResult
    public func commitPush(_ intent: PushIntent, now: Date = Date()) async throws -> Entity {
        let entity = Entity(
            id: Self.pushID(for: intent, now: now),
            kind: intent.kind,
            title: intent.title,
            detail: nil,
            dueAt: intent.dueAt,
            // Not a guess, so not scored like one. Confidence exists to rank inferences
            // against each other and has no meaning for something the user typed.
            confidence: 1.0,
            pinned: false,
            corrected: false,
            deleted: false,
            source: .authored,
            createdAt: now,
            updatedAt: now
        )
        try await store.upsert(entity: entity)
        Log.shared.info("push committed: \(intent.kind.rawValue) '\(intent.title)'")
        return entity
    }

    /// Writes a journal entry, filed under the day it is about.
    ///
    /// Two dates, on purpose, and they are usually the same one. `updatedAt` is the day the
    /// entry belongs to — the day view filters on it, the month grid counts it, *on this day*
    /// groups by it — and `createdAt` is the moment somebody actually typed it. Writing about
    /// last Tuesday on a Sunday has to file the entry under Tuesday or the calendar lies about
    /// when the life happened; stamping it Tuesday outright would have the record claim it was
    /// written then, which it was not. So it carries both, and the surface says so when they
    /// disagree.
    ///
    /// Separate from ``commitPush(_:now:)`` because that path is the chat's, has exactly one
    /// call site by design (CF-51), and cannot express the two dates.
    @discardableResult
    public func writeEntry(_ text: String, filedAt: Date, now: Date = Date()) async throws -> Entity {
        let title = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw MemoirError.storage("an empty entry is not an entry") }
        let entity = Entity(
            id: Self.pushID(for: PushIntent(kind: .note, title: title, source: title), now: filedAt),
            kind: .note,
            title: title,
            detail: nil,
            dueAt: nil,
            // Not a guess, so not scored like one.
            confidence: 1.0,
            source: .authored,
            // The marker. Until schema v12 nothing in the row said "a person wrote this about a
            // day": a journal entry and a note pushed from the chat were structurally identical,
            // and the only way to tell them apart was the accidental pair `confidence == 1.0 &&
            // detail == nil`. Two columns lining up by coincidence is not an answer, and the
            // cost was measured — the six entries on the real vault ranked 20th, 149th, 15th,
            // 53rd, 42nd and 97th inside their own days against a cap of eight, so none of the
            // user's own words had ever reached an answer.
            filedAt: filedAt,
            createdAt: now,
            updatedAt: filedAt
        )
        try await store.upsert(entity: entity)
        Log.shared.info("journal entry written, filed under \(filedAt)")
        return entity
    }

    /// Rewrites a journal entry the user has already written.
    ///
    /// Separate from ``commitPush(_:now:)`` and it has to be: that path derives the id from the
    /// text, so putting an edit through it produces a new entry beside the old one rather than
    /// changing anything. This updates the row that is already there, and leaves the date it is
    /// filed under exactly where it was.
    ///
    /// The `corrected` flag is deliberately not set. That flag means "the user fixed something
    /// Memoir guessed" — it is what shields an inferred entity from being overwritten by the
    /// next extraction pass, and it is reported over MCP as *you corrected this*. Fixing a typo
    /// in your own diary is not a correction of anything Memoir claimed.
    public func rewriteEntry(id: ID, title: String) async throws {
        let text = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        try await store.rewriteNote(id: id, title: text)
        Log.shared.info("journal entry rewritten")
    }

    /// The id a pushed entity gets, and the one place the difference between a *thing* and a
    /// *dated record* is decided.
    ///
    /// Everything here used to be identified by its own normalised text, which is right for most
    /// kinds and was quietly destroying the journal. `normalizedTitle` strips case and
    /// punctuation, `upsert` is `ON CONFLICT(id) DO UPDATE`, and journal entries are stored as
    /// notes, so writing *"Long day."* in March and *"long day"* in June produced **one row**,
    /// dated June. The March entry was gone, and because the journal groups by `updatedAt`, March
    /// also lost the only thing written in it. No error, no warning, and it is the most valuable
    /// data in the product.
    ///
    /// - **A note is an event.** What somebody wrote tonight is not the same object as the
    ///   identical sentence written in April; it is a second act of writing. So its identity
    ///   carries the second it happened in. Two entries with the same words in the same second is
    ///   a double submit, and collapsing that is correct.
    /// - **Everything else is a thing.** Typing "send the invoice" twice is one task, and text
    ///   identity is what makes that work. Unchanged.
    static func pushID(for intent: PushIntent, now: Date) -> ID {
        let normalized = MemoryText.normalizedTitle(intent.title)
        switch intent.kind {
        case .note:
            return MemoryText.stableID(
                intent.kind.rawValue, normalized, ISO8601DateFormatter().string(from: now)
            )
        case .person, .project, .thread, .decision, .commitment, .place:
            return MemoryText.stableID(intent.kind.rawValue, normalized)
        }
    }

    /// Marks a commitment done.
    ///
    /// CF-56. Completion sets `completed_at` (schema v5), which is what makes it permanent:
    /// ``commit(_:now:)`` refuses to resurrect a completed row exactly as it refuses a
    /// deleted one. Unlike the soft delete this once was, a completed todo stays *visible*
    /// (struck through in the list with the time it was finished), and the user can reopen
    /// it, because completion is permanent against extraction, not against changing your mind.
    ///
    /// - Parameters:
    ///   - entityID: the commitment to mark done.
    ///   - at: the completion instant, or nil to reopen. Injected by tests.
    public func completePush(entityID: ID, at: Date? = Date()) async throws {
        try await store.setCompleted(entityID: entityID, at: at)
    }

    // MARK: - Vault import

    /// Imports a vault folder: notes become captures, titles become authored entities,
    /// and the merge laws apply. Safe to re-run; the pass is idempotent.
    @discardableResult
    public func importVault(at folder: URL, now: Date = Date()) async throws -> VaultImporter.Summary {
        // The scan is synchronous filesystem work over a folder of unknown size; run
        // it detached so a slow disk never blocks this actor (which also serves the
        // ask pipeline) for the duration of a directory walk.
        let (captures, result) = try await Task.detached(priority: .utility) {
            try VaultImporter.scan(folder: folder, now: now)
        }.value
        for capture in captures {
            try await store.insert(capture: capture)
        }
        let committed = try await commit(result, now: now)
        Log.shared.info("vault import: \(captures.count) notes read, \(committed) entities touched")
        return VaultImporter.Summary(notesRead: captures.count, entitiesCommitted: committed)
    }

    /// Imports Contacts and Calendar once, so the memory reaches back years on day one.
    ///
    /// Contacts become authored people; calendar events become dated captures. Same commit
    /// path and same merge laws as the vault, so a person who is already known is merged into
    /// rather than duplicated, and re-running is safe.
    ///
    /// A source the user declined contributes nothing and is not an error.
    @discardableResult
    public func importLife(
        sources: LifeImporter.Sources = .init(),
        since: Date? = nil,
        now: Date = Date()
    ) async throws -> LifeImporter.Summary {
        // Reading a decade of calendar is slow filesystem-and-XPC work; keep it off this
        // actor, which also serves the ask pipeline.
        let (captures, result, summary) = await Task.detached(priority: .utility) {
            LifeImporter.scan(sources: sources, since: since, now: now)
        }.value

        for capture in captures {
            // A contacts row is dated "when we read the address book", not by anything that
            // happened. Re-running would therefore march every contact's timestamp forward to
            // today, so 400 people would show up in "what happened this morning" on every
            // pass. Keep the timestamp from the first time we saw it; the text still updates,
            // which is what picks up a renamed contact.
            //
            // Calendar and photo rows are dated by the event and the day, so they must be
            // allowed to move: an event dragged to next Tuesday should be dated next Tuesday.
            if capture.appBundleID == LifeImporter.contactsBundleID,
               let existing = try await store.capture(id: capture.id) {
                try await store.insert(capture: CaptureEvent(
                    id: capture.id,
                    ts: existing.ts,
                    appBundleID: capture.appBundleID,
                    appName: capture.appName,
                    windowTitle: capture.windowTitle,
                    text: capture.text,
                    textHash: capture.textHash
                ))
                continue
            }
            try await store.insert(capture: capture)
        }
        let committed = try await commit(result, now: now)
        Log.shared.info(
            "life import: \(summary.peopleImported) people, \(summary.eventsImported) events, \(summary.photoDaysImported) photo days, \(summary.placesFound) places, \(committed) entities touched"
        )
        return summary
    }

    // MARK: - Work spans

    /// Contiguous stretches of work on one thing across apps, for a time window.
    ///
    /// Sessions are cut at their captures, each interval is labelled by the ontology
    /// (entity titles and aliases, authored names first), and adjacent same-label
    /// intervals merge across apps. Unlabelled time degrades honestly to the app name.
    public func workSpans(from: Date, to: Date) async throws -> [WorkSpan] {
        // Clipped, not just fetched: overlap-selected sessions are cut to the window
        // so no minute outside [from, to] is ever attributed inside it, and the
        // capture limit is applied to the window itself, not to everything since.
        let sessions = WorkSpanBuilder.clip(
            try await store.sessions(from: from, to: to), from: from, to: to
        )
        // Captures reach back before the window so a session already in progress
        // keeps the label of the screen that was showing when it began. Sessions are
        // still clipped, so no out-of-window *time* is attributed, only the name.
        let captures = try await store.captures(
            from: from.addingTimeInterval(-WorkSpanBuilder.defaultCarryForward), to: to, limit: 5_000
        )
        let ontology = Ontology.build(from: try await store.entities(kind: nil, includeDeleted: false))
        return WorkSpanBuilder.spans(sessions: sessions, captures: captures, ontology: ontology)
    }

    // MARK: - Proof of work

    /// A reconstructed timesheet for a range: per day, per thing, with evidence.
    public func timesheet(from: Date, to: Date) async throws -> Timesheet {
        let spans = try await workSpans(from: from, to: to)
        return TimesheetBuilder.build(spans: spans, from: from, to: to)
    }

    /// The weekly review: where time went, what surfaced, what is owed. Markdown.
    public func weeklyReview(from: Date, to: Date, now: Date = Date()) async throws -> String {
        let sheet = try await timesheet(from: from, to: to)
        let all = try await store.entities(kind: nil, includeDeleted: false)
        return ReviewBuilder.markdown(
            sheet: sheet,
            touched: all.filter { $0.updatedAt >= from && $0.updatedAt <= to },
            commitments: all.filter { $0.kind == .commitment && !$0.provisional },
            now: now
        )
    }

    /// Read-only entity snapshot, for draft assembly in extensions that cannot see
    /// the private store.
    func entitiesSnapshot() async throws -> [Entity] {
        try await store.entities(kind: nil, includeDeleted: false)
    }

    /// Capture insert for extensions that cannot see the private store. The vault
    /// importer and proposal acceptance both record their source text this way so
    /// their entities stay traceable (CF-15).
    func storeInsert(_ capture: CaptureEvent) async throws {
        try await store.insert(capture: capture)
    }

    // MARK: - Retention

    /// Deletes captures older than `captureDays`. Entities are never touched.
    ///
    /// This is the two-tier retention rule: raw text rolls off, structured memory is kept.
    ///
    /// - Parameters:
    ///   - captureDays: how many days of raw captures to keep.
    ///   - now: the instant the cutoff is measured back from. Defaults to the wall clock;
    ///     integration tests inject a fixed date so retention is reproducible.
    /// - Returns: the number of captures deleted.
    ///
    /// Captured screen text only. Imported history (Contacts, Calendar, Photos, the vault) is
    /// never swept by time, because those rows are dated by when the thing happened and the
    /// sweep would take the decade the import exists to provide. `ImportedSource` carries the
    /// argument in full.
    @discardableResult
    public func applyRetention(captureDays: Int, now: Date = Date()) async throws -> Int {
        guard captureDays > 0 else { return 0 }
        let cutoff = now.addingTimeInterval(-Double(captureDays) * 86_400)
        let removed = try await store.purgeCaptures(olderThan: cutoff)
        if removed > 0 {
            Log.shared.info("retention removed \(removed) captures older than \(captureDays)d")
        }
        return removed
    }
}
