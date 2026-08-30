import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Normalises a question before anything tries to route or retrieve it.
///
/// **The problem.** Routing classifies the phrasing the user happened to type, so four ways of
/// asking the same thing land in four places. Measured on the tier1 group with a frontier
/// judge, every one of these failed while `"what was I just doing"` passed:
///
///     "where was I"   "pick me up where I left off"   "what have I been up to"   "catch me up"
///
/// They mean the same thing. Under classification they are four separate problems, and the
/// only fix available is another phrase in a list. There are infinitely many phrasings and the
/// list is finite, so that approach cannot converge - it has been losing all week, one funeral
/// at a time.
///
/// **The fix.** Rewrite first, then route the rewritten form. One transformation covers
/// infinite inputs where a list covers exactly what is in it. Published work on small-model
/// memory agents reports the same cascade we already have topping out near 88% routing
/// accuracy, and names query rewriting as the alternative rather than a better classifier.
///
/// It also matters that rewriting is a job a small model is GOOD at. It is a transformation:
/// short input, short output, nothing to search. Classifying an unfamiliar phrasing is a
/// judgement call, which is the thing small models are weak at. Same model, easier job.
///
/// **What it never does.** The canonical form is a search key and nothing else. The original
/// question is what reaches the answer prompt and the grounding guards, because the user asked
/// what they asked, and a figure they typed themselves is evidence that the rewrite could drop.
public actor QueryRewriter {

    /// The closed set of things a question can be normalised to.
    ///
    /// Deliberately small. A rewriter that can emit anything is a paraphraser, and paraphrasing
    /// is how "what url was the motion website" quietly becomes "what websites did I visit".
    /// These are the shapes the retrieval layer actually distinguishes; anything else is left
    /// alone rather than forced into the nearest one.
    public enum Canonical: String, Sendable, CaseIterable {
        case openCommitments = "what are my open commitments"
        case recentActivity = "what was I doing recently"
        case timeToday = "how much time did I spend today"
        case findSomethingSeen = "find something I saw"

        /// True when this shape is specific enough to retrieve against on its own.
        var isRetrievable: Bool { self != .findSomethingSeen }

    /// The category this shape always routes to.
        ///
        /// A canonical form must never be routed. It comes from a closed set of four strings that
        /// this file chose, so asking a classifier to guess at it is asking a model to tell us
        /// something we decided ourselves.
        ///
        /// That was not hypothetical. "what was I doing recently" scored a routing margin of
        /// **0.018** - the most ambiguous input the router has ever seen, far below the 0.075
        /// confidence threshold - so every rewritten question escalated to the guided classifier
        /// and paid a full model call. Measured: 8.28s against 0.85s for a question that skipped
        /// the rewrite. The step added to make routing reliable was making it slow by asking the
        /// router to re-derive its own answer.
        public var category: QuestionCategory {
            switch self {
            case .openCommitments: return .recall
            case .recentActivity: return .resumption
            case .timeToday: return .accounting
            case .findSomethingSeen: return .recall
            }
        }

    }

    /// Rewrites already resolved this session.
    ///
    /// The whole reason this is affordable. The same phrasing always yields the same canonical
    /// form, and a person's vocabulary is small in practice: "catch me up" gets typed a hundred
    /// times and pays for a model call once.
    private var cache: [String: Canonical?] = [:]

    /// What "this year" means. Only the year-constraint guard below reads it.
    ///
    /// Injectable for the same reason `BrainRouter`'s clock is: the guard decides whether a
    /// year the user typed is a *constraint* by comparing it against the current one, so a
    /// fixture run anchored to a past year and a wall clock that has moved on would disagree
    /// about the same question. Nothing in the suite names a year but 1995, so this is closing
    /// the hole rather than fixing a symptom, which is the only time it is cheap to close.
    private let now: @Sendable () -> Date

    public init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
    }

    /// Canonicalises a question, or nil when it does not fit a known shape.
    ///
    /// - Parameter alreadyCertain: true when a deterministic rule has already matched, in which
    ///   case there is nothing to normalise and no call is made. This is what keeps the fast
    ///   path fast: most questions never reach the model at all.
    /// - Returns: the canonical form, or nil to route and retrieve the question as typed.
    public func canonical(for question: String, alreadyCertain: Bool = false) async -> Canonical? {
        guard !alreadyCertain else { return nil }

        // Scope is not the rewriter's to decide, and this is the line that says so.
        //
        // Every canonical shape is in scope (that is what the set is FOR), so a rewriter
        // asked to pick one from a question Memoir cannot answer has no honest move
        // available except `somethingElse`, and a 3B model does not reliably find it. Its
        // errors are therefore one-way: they can only carry a question INTO scope. Measured
        // on the honesty group, three of the four failures were laundered here:
        // "how much money did I spend today" came back `timeToday`, "what did I buy today"
        // and "what did I have for lunch" came back `recentActivity`. Because a
        // canonical form is never routed, the router never saw them. It would have got all
        // three right. The one question the rewriter left alone, "what is my bank balance",
        // was the one question that was refused correctly.
        //
        // So the rewriter chooses among retrieval shapes for questions that HAVE one. Whether
        // a question has one at all is settled first, for free, and never by a model.
        guard !QuestionRouter.isStructurallyUnknowable(question) else { return nil }

        // The same one-way error, on the time axis rather than the topic axis.
        //
        // "What was I doing in 1995" is answered with today's app table. `byWording` matches
        // "what was i doing", returns `recentActivity`, and the canonical string that reaches
        // the brain is "what was I doing recently", which does not contain 1995. So
        // `RulesOnlyBrain.mentionedYear`, the guard written for exactly this question, never
        // sees the token it exists to catch. The rewrite did not misjudge the question; it
        // deleted the evidence that the question was unanswerable.
        //
        // A canonical form is a SEARCH KEY, and the rewriter is allowed to drop phrasing.
        // What it must not drop is a CONSTRAINT: a word that narrows which records could
        // possibly answer. A year is the sharpest case: no rephrasing of "recently" can be
        // right about 1995, so a question that names another year is handed back whole.
        if let year = RulesOnlyBrain.mentionedYear(in: question),
           year != Calendar.current.component(.year, from: now()) {
            return nil
        }

        // And the same error on the axis of WHERE. Placed here rather than inside
        // ``byWording`` on purpose: the model stage below drops a named app just as happily as
        // the rule stage did, so a guard that only covered the rules would work on a Mac
        // without Apple Intelligence and quietly stop working on one with it.
        guard !Self.namesAScope(question) else { return nil }

        let key = Self.cacheKey(question)
        if let hit = cache[key] { return hit }

        // Free first, for the same reason the router does: most rewrites are decidable from
        // wording alone, and a model call to learn that "catch me up" means "catch me up" is
        // a second of someone's life spent badly.
        if let obvious = Self.byWording(question) {
            cache[key] = obvious
            return obvious
        }

        let resolved = await modelRewrite(question)
        cache[key] = resolved
        return resolved
    }

    /// Normalised for caching, so capitalisation and stray punctuation do not each pay a call.
    static func cacheKey(_ question: String) -> String {
        question.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// The rule layer: phrasings common enough to be worth deciding for free.
    ///
    /// Kept, not replaced. The research is explicit that the rule layer earns its place - it is
    /// free and it is right when it fires. What changes is that it stops being the ONLY
    /// mechanism, so a phrasing nobody anticipated has somewhere to go.
    static func byWording(_ question: String) -> Canonical? {
        let q = " " + question.lowercased()
            .replacingOccurrences(of: "'", with: "")
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined(separator: " ") + " "

        // Superlatives belong here, not in search.
        //
        // "what's the last site I was looking at" was answered "exaltahalo.com" when the real
        // last page was a YouTube video twenty minutes earlier. It went to semantic search,
        // which ranks by RELEVANCE - and "last" is not a topic, it is an ORDER. A relevance
        // ranker will essentially never return the most recent thing except by accident.
        //
        // The resumption timeline is already sorted by time, so a superlative just needs to be
        // sent there. It is the one shape where the answer is a sort, not a search.
        let resumption = ["catch me up", "where was i", "where did i leave off", "left off",
                          "pick me up where", "what have i been up to", "what was i just doing",
                          "what was i doing", "bring me up to speed", "recap"]
        // Superlatives are deliberately NOT rewritten. "what was the last site" asks for ONE
        // row at the top of a sorted list, and the canonical form "what was I doing recently"
        // asks for a summary - rewriting it throws away the very thing that makes it
        // answerable exactly. RulesOnlyBrain.asksForMostRecent handles them instead.
        if resumption.contains(where: { q.contains(" " + $0 + " ") }) { return .recentActivity }

        let commitments = ["on my plate", "to do list", "todo list", "my todos", "what do i owe",
                           "anything due", "whats overdue", "what did i promise",
                           "forgetting something", "my commitments", "on my list"]
        if commitments.contains(where: { q.contains(" " + $0 + " ") }) { return .openCommitments }

        let time = ["how much time", "how long was i", "how long have i",
                    "time spent", "which app took"]
        if time.contains(where: { q.contains(" " + $0 + " ") }) { return .timeToday }

        return nil
    }

    /// True when a question names WHERE to look, not just what to look for.
    ///
    /// The third axis, after scope and the year, and the same one-way error each time. "How
    /// much time did I spend in chrome today" matches `how much time`, canonicalises to "how
    /// much time did I spend today", and the app is gone. That would be survivable if a
    /// canonical form were only a search key. But `BrainRouter` hands it to `RulesOnlyBrain`
    /// as the question to CLASSIFY, so the floor matches the canonical string exactly and
    /// renders the whole-day app table. Measured on the fixture world: asked about Chrome, the
    /// answer was four apps and their totals, every figure correct and none of them the one
    /// asked for.
    ///
    /// It applies to every shape, not just time. "Catch me up on fenwick" is a lookup about
    /// fenwick, which `RulesOnlyBrain.classify` already says in as many words; rewriting it to
    /// "what was I doing recently" throws the subject away before that line can run.
    ///
    /// Temporal words are not scopes. "In the morning" and "on monday" narrow WHEN, which
    /// every canonical form already carries.
    static func namesAScope(_ question: String) -> Bool {
        let temporal: Set<String> = [
            "the", "this", "that", "today", "todays", "yesterday", "tomorrow", "morning",
            "afternoon", "evening", "night", "week", "weeks", "weekend", "month", "year",
            "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
            "average", "total", "it", "them", "my", "me", "a", "an", "here", "there",
        ]
        let words = question.lowercased()
            .replacingOccurrences(of: "\u{2019}", with: "")
            .replacingOccurrences(of: "'", with: "")
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        for (index, word) in words.enumerated() where ["in", "on", "with", "inside"].contains(word) {
            guard index + 1 < words.count else { continue }
            let next = words[index + 1]
            // A number after "in" or "on" is a date, never a place: "in 2026", "on the 5th".
            // The year guard above already decides whether that date rules the question out.
            if next.allSatisfy(\.isNumber) { continue }
            if !temporal.contains(next) { return true }
        }
        return false
    }

    /// The model layer, for phrasings the rules never anticipated.
    ///
    /// Gated by ``ModelGate``: this stage runs before routing whatever `--brain` says, so an
    /// eval claiming to be deterministic is not while it can fire. Disabled, the rule layer
    /// above still runs and the question is routed exactly as typed.
    private func modelRewrite(_ question: String) async -> Canonical? {
        guard !ModelGate.modelsDisabled else { return nil }
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            guard SystemLanguageModel.default.availability == .available else { return nil }
            do {
                let session = LanguageModelSession(instructions: Self.instructions)
                let reply = try await session.respond(to: question, generating: RewrittenQuery.self)
                return reply.content.shape.asCanonical
            } catch {
                // Falling through to nil means the question is routed exactly as it is today.
                // A rewriter that cannot run must cost nothing, not break the question.
                Log.shared.debug("query rewrite failed: \(error.localizedDescription)")
                return nil
            }
        }
        #endif
        return nil
    }

    static let instructions = """
    Decide which of these a question is really asking for. Do not answer it.

    openCommitments: things the user has to do, promised, or owes. Any way of asking for their \
    list, their tasks, what is due, or what they are forgetting.
    recentActivity: what they were doing lately, or picking up where they left off, however \
    loosely phrased.
    timeToday: how long something took, or where their time went.
    findSomethingSeen: looking for one specific thing they saw before - a page, a repository, \
    a name, a URL.
    somethingElse: none of the above, including greetings, complaints, and questions about \
    things a screen reader cannot know.
    """
}

#if canImport(FoundationModels)

/// The constrained output. One choice from a closed set, so there is nothing to parse and
/// nothing for the model to invent.
@available(macOS 26.0, *)
@Generable
enum RewrittenShape: String {
    case openCommitments
    case recentActivity
    case timeToday
    case findSomethingSeen
    case somethingElse

    var asCanonical: QueryRewriter.Canonical? {
        switch self {
        case .openCommitments: return .openCommitments
        case .recentActivity: return .recentActivity
        case .timeToday: return .timeToday
        case .findSomethingSeen: return .findSomethingSeen
        case .somethingElse: return nil
        }
    }
}

@available(macOS 26.0, *)
@Generable
struct RewrittenQuery {
    @Guide(description: "which of the five shapes this question is really asking for")
    var shape: RewrittenShape
}

#endif
