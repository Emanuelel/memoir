import Foundation

/// Picks which brain answers, and falls back when the preferred one cannot.
///
/// The fallback chain is **preferred, then `appleOnDevice`, then `rulesOnly`**.
///
/// The rule that matters most: *Memoir never silently falls back to a cloud brain.* The two fallback
/// steps are both local by construction, and while `BrainConfig.allowCloud` is `false` every cloud
/// brain is removed from the chain entirely, even when the user has selected one as preferred.
/// The last link, `RulesOnlyBrain`, is always available, so `answer` always returns something.
public actor BrainRouter {
    /// How long an availability probe is trusted before it is run again.
    private static let availabilityTTL: TimeInterval = 30

    /// The user's choice. May be unusable, in which case the chain moves on without it.
    private var preferred: BrainKind

    /// The memory, needed to build `RulesOnlyBrain`.
    private let store: Store

    /// Current settings. The API key inside is never persisted or logged by this type.
    private var config: BrainConfig

    /// Cached availability probes, so opening the ask bar does not re-shell-out every keystroke.
    private var availabilityCache: [BrainKind: (value: Bool, checkedAt: Date)] = [:]

    /// Cached Keychain lookup. Outer nil means "not looked up yet".
    private var keyCache: String??

    /// True once we have logged the "cloud brain selected but cloud is off" warning.
    private var loggedCloudBlock = false

    /// The clock every answer this router assembles is dated against.
    ///
    /// It exists for one reason and it is not testing: `MemoryService.context` already took a
    /// reference date, so an eval run could retrieve a fixture day while the floor underneath
    /// went on rendering "today", "overdue" and "due tomorrow" from the wall clock. That
    /// produces output which looks deterministic, passes, and then changes on its own once a
    /// day, the worst shape a fixture failure can take, because nothing goes red until a date
    /// rolls over and by then the run that broke it is long gone.
    ///
    /// So the clock has to reach every `RulesOnlyBrain` this file builds, and the push parser
    /// with it: "remind me to send the invoice friday" resolves *which* Friday from here.
    /// Latency is deliberately not on this clock: a measured duration must be measured.
    private let now: @Sendable () -> Date

    /// Where brains come from. `nil` in production, where they are built from the config.
    ///
    /// Three of the four brains leave this process: the on-device model, the Anthropic API
    /// and the `claude` subprocess. The integration suite substitutes those so the fallback
    /// chain can be exercised without a model, a network or a subprocess, while
    /// `RulesOnlyBrain` and the store underneath it stay real. Nothing about the routing
    /// policy is bypassed: the factory is consulted only *after* ``isAllowed(_:)`` has
    /// passed, so a substituted cloud brain is no easier to reach than a real one.
    private let brainFactory: (@Sendable (BrainKind) -> (any Brain)?)?

    /// Creates a router.
    /// - Parameters:
    ///   - preferred: the brain the user picked in settings.
    ///   - store: the memory, used by the rules-only fallback.
    ///   - config: brain settings. `allowCloud` defaults to `false`.
    ///   - now: the instant "today", "overdue" and a parsed due date are all measured from.
    ///     Defaults to the wall clock, which is what the app wants. `memoir-ask --now` is the
    ///     only caller that passes anything else.
    public init(
        preferred: BrainKind,
        store: Store,
        config: BrainConfig,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.preferred = preferred
        self.store = store
        self.config = config
        self.now = now
        self.brainFactory = nil
        if let key = config.anthropicAPIKey, !key.isEmpty {
            self.keyCache = .some(key)
        }
    }

    /// Creates a router whose brains are supplied by `brainFactory` rather than built from
    /// the configuration. Deliberately not `public`: this exists so the integration suite can
    /// drive the fallback chain deterministically.
    ///
    /// Returning `nil` from the factory means "this kind cannot be constructed", exactly as a
    /// missing API key does in production.
    init(
        preferred: BrainKind,
        store: Store,
        config: BrainConfig,
        now: @escaping @Sendable () -> Date = { Date() },
        brainFactory: @escaping @Sendable (BrainKind) -> (any Brain)?
    ) {
        self.preferred = preferred
        self.store = store
        self.config = config
        self.now = now
        self.brainFactory = brainFactory
        if let key = config.anthropicAPIKey, !key.isEmpty {
            self.keyCache = .some(key)
        }
    }

    // MARK: - Configuration

    /// The brain that would answer right now, after availability checks and fallback.
    public func current() async -> BrainKind {
        for kind in chain() where await isAvailable(kind) {
            return kind
        }
        return .rulesOnly
    }

    /// The brain the user selected, regardless of whether it can currently answer.
    public func preferredKind() -> BrainKind { preferred }

    /// Changes the preferred brain and drops cached availability.
    public func setPreferred(_ kind: BrainKind) async {
        guard kind != preferred else { return }
        preferred = kind
        availabilityCache.removeAll()
        loggedCloudBlock = false
        Log.shared.info("Preferred brain set to \(kind.rawValue).")
        if kind.isCloud && !config.allowCloud {
            Log.shared.warn("\(kind.displayName) is selected but cloud use is off, so local brains will answer.")
        }
    }

    /// Replaces the configuration, dropping cached availability and the cached key.
    public func setConfig(_ newConfig: BrainConfig) async {
        config = newConfig
        keyCache = nil
        if let key = newConfig.anthropicAPIKey, !key.isEmpty { keyCache = .some(key) }
        availabilityCache.removeAll()
        loggedCloudBlock = false
        Log.shared.info("Brain config updated: \(newConfig.redactedDescription)")
    }

    /// The current configuration. The API key field is cleared, so this is safe to hand to the UI.
    public func redactedConfig() -> BrainConfig {
        var copy = config
        copy.anthropicAPIKey = nil
        return copy
    }

    /// Forgets every cached availability probe. Call after installing Claude Code or enabling
    /// Apple Intelligence so the change is picked up immediately.
    public func refresh() async {
        availabilityCache.removeAll()
        keyCache = nil
        ClaudeCodeBrain.resetDiscoveryCache()
    }

    // MARK: - Availability

    /// Every brain that can answer right now, in fallback order.
    ///
    /// Cloud brains are omitted entirely while `allowCloud` is off, so this list is exactly the
    /// set of brains that could actually be used.
    public func available() async -> [BrainKind] {
        var result: [BrainKind] = []
        for kind in BrainKind.allCases where isAllowed(kind) {
            if await isAvailable(kind) { result.append(kind) }
        }
        return result.sorted { rank($0) < rank($1) }
    }

    /// A sentence explaining the state of one brain, for the settings UI.
    ///
    /// Reports the cloud block explicitly rather than pretending the brain is broken.
    public func availabilityDetail(for kind: BrainKind) async -> String {
        if kind.isCloud && !config.allowCloud {
            return "\(kind.displayName) is switched off. Turn on \"Allow cloud brains\" to use it."
        }
        if kind == .localNetwork && !config.allowLocalNetwork {
            return "\(kind.displayName) is switched off. Turn on \"Allow a model on my network\" to use it."
        }
        guard let brain = makeBrain(kind) else {
            return "\(kind.displayName) is not configured."
        }
        return await brain.availabilityDetail()
    }

    /// Availability for every brain, cloud block included. Handy for a settings screen.
    public func availabilityReport() async -> [BrainKind: String] {
        var out: [BrainKind: String] = [:]
        for kind in BrainKind.allCases {
            out[kind] = await availabilityDetail(for: kind)
        }
        return out
    }

    // MARK: - Answering

    /// Answers a question, walking the fallback chain until one brain succeeds.
    ///
    /// A brain that is unavailable is skipped. A brain that throws is logged and skipped.
    /// `RulesOnlyBrain` terminates the chain and always produces an answer.
    /// - Parameter category: the routed question kind, when the caller has one. Lets the
    ///   router answer or refuse without invoking a brain at all.
    /// - Parameter canonicalQuestion: the normalised form, when the caller rewrote the
    ///   question before retrieving. Used ONLY where a brain picks a template from wording -
    ///   `RulesOnlyBrain` classifies the text it is handed, so without this it re-derives its
    ///   own answer shape from the raw phrasing and "catch me up" and "where was I" split again
    ///   two layers below the router that just unified them.
    ///
    ///   It is deliberately not used for anything else. Grounding, push parsing, challenges and
    ///   the answer prompt all keep the ORIGINAL question, because a figure the user typed is
    ///   evidence and the rewrite could have dropped it.
    public func answer(
        question: String,
        context: ContextPacket,
        category: QuestionCategory? = nil,
        canonicalQuestion: String? = nil
    ) async throws -> BrainAnswer {
        if let settled = Self.settledBeforeSplitting(
            question: question, category: category, reference: now()) {
            return settled
        }

        // The user's own messages are answered from the parse, never generated (CF-61).
        //
        // "what did I write on whatsapp" fell to the general brief and was answered with a
        // status report ("10 open commitments. Recently in play: ..."). Same reasoning as
        // the superlative below, and the same placement: sender attribution must come from
        // `MessageParser`, which reads names off the screen, so a model has nothing to add
        // to the filtered list and a whole class of invention to subtract. Checked first
        // because "the last thing I sent" is both shapes at once, and the messages reading
        // is the one that was asked.
        if RulesOnlyBrain.asksForMyMessages(question) {
            return try await floorBrain().answer(question: question, context: context)
        }

        // A superlative is answered from the sorted list, never generated.
        //
        // Handed a correctly ordered timeline beginning with Gmail, the model answered
        // "Google Maps" - a page that appeared nowhere in it. Retrieval order was never the
        // bug. There is nothing a model can add to "the first row of this list", and a whole
        // class of invention it can subtract.
        //
        // It sits here rather than in `settledBeforeSplitting` because it needs the store and
        // the context, which that static helper deliberately does not have.
        if RulesOnlyBrain.asksForMostRecent(question) {
            return try await floorBrain().answer(question: question, context: context)
        }

        // Compound questions get every part answered.
        //
        // "how much time on the laptop today and how much time on claude on %" returned only
        // a duration, silently dropping half of what was asked. A memory that answers half a
        // question and says nothing about the rest is quietly unreliable, which is worse than
        // one that refuses outright.
        let parts = QuestionRouter.parts(question)
        if parts.count > 1 {
            var answers: [String] = []
            var cited: [ID] = []
            var brain = BrainKind.rulesOnly
            for part in parts {
                // The PARENT's category, not nil: a compound accounting question has
                // accounting parts, and passing nil silently disabled the duration guard for
                // exactly the question that motivated this whole path.
                let reply = try await answer(question: part, context: context, category: category)
                answers.append(reply.text.trimmingCharacters(in: .whitespacesAndNewlines))
                cited.append(contentsOf: reply.citedCaptureIDs)
                brain = reply.brain
            }
            return BrainAnswer(text: answers.joined(separator: "\n\n"), brain: brain,
                               citedCaptureIDs: cited, latency: 0)
        }

        if let settled = Self.settledAfterSplitting(question: question, category: category) {
            return settled
        }

        let order = chain()
        var lastError: (any Error)?

        for kind in order {
            guard let brain = makeBrain(kind) else { continue }
            guard await isAvailable(kind) else { continue }
            do {
                var answer = try await brain.answer(
                    question: kind == .rulesOnly ? (canonicalQuestion ?? question) : question,
                    context: context)
                if kind != preferred {
                    Log.shared.info("Answered with \(kind.rawValue) after \(preferred.rawValue) was unavailable.")
                }
                // Enforce grounding rather than asking for it. A figure the evidence never
                // contained is fabricated, and shipping it would quietly destroy trust in
                // everything else the memory says.
                //
                // Only generative brains are checked. `rulesOnly` computes its figures by
                // querying the store directly ("1h 26m tracked", "48 min in Chrome"), so
                // they are true by construction while being absent from the context summary.
                // Guarding it would reject correct arithmetic as invention.
                let evidence = context.summary + "\n" + question
                let invented = kind == .rulesOnly
                    ? []
                    : Grounding.ungroundedNumbers(in: answer.text, evidence: evidence)
                // Actions are checked against the CONTEXT ALONE, never the question. A
                // number the user types is evidence for that number; a verb the user types
                // is not evidence that they did it. Asking "what note did I create" let the
                // question ground the answer "You created a note" about a note only read.
                let actions = kind == .rulesOnly
                    ? []
                    : Grounding.unsupportedActions(in: answer.text, evidence: context.summary)
                // Hosts, like actions, are checked against the CONTEXT ALONE: a domain the
                // user typed (or mistyped) is not evidence that it exists.
                let hosts = kind == .rulesOnly
                    ? []
                    : Grounding.unsupportedHosts(in: answer.text, evidence: context.summary)
                // Accounting is the one category whose correct answers are known exactly
                // before the model runs, so its durations are checked against the computed
                // table rather than against loose digits. The number guard cannot do this:
                // every duration is written in small integers, and 0–10 are exempt.
                let durations = (kind == .rulesOnly || category != .accounting)
                    ? []
                    : Grounding.unsupportedDurations(in: answer.text, evidence: context.summary)
                // Agreeing with a challenge without re-deriving turns a wrong answer into a
                // CONFIRMED wrong answer, and teaches the user that pushing back does
                // nothing. Observed live: "1 minute and 43 seconds on Claude" (really 2h 10m),
                // challenged, and restated as "You spent 1 minute on Claude."
                if kind != .rulesOnly, Grounding.isChallenge(question),
                   Grounding.assertsWithoutEvidence(answer.text) {
                    // "are you sure?" answered "Yes, I am sure." A challenge asks Memoir to
                    // check, and asserting instead spends the trust that checking would have
                    // earned. Re-derive from the store, which cannot bluff.
                    Log.shared.warn("\(kind.rawValue) asserted confidence instead of re-deriving; checking again")
                    answer = await self.recheck(answer, context: context)
                } else if kind != .rulesOnly, Grounding.isChallenge(question),
                   let previous = AskLog.shared.recent(limit: 1).first?.answer,
                   Grounding.capitulates(answer: answer.text, toChallenge: question,
                                         previousAnswer: previous) {
                    Log.shared.warn("\(kind.rawValue) capitulated to a challenge; re-deriving from the store")
                    answer = await self.rejected(answer, question: question, context: context,
                                                 instead: Grounding.refusal)
                } else if kind != .rulesOnly, Grounding.isModelRefusal(answer.text) {
                    // A declining model is usually RIGHT, and the temptation to route around
                    // it is how a fallback starts fabricating. Substituting the floor here
                    // answered "what was I doing in 1995" with this afternoon's pages,
                    // the exact failure the floor's own guard had just been added to prevent,
                    // reintroduced one layer down.
                    //
                    // So this is a translation, not a retry: same verdict, said in Memoir's
                    // voice instead of the model's. "I cannot answer that question" is not a
                    // sentence this product says.
                    Log.shared.info("\(kind.rawValue) declined; restating in Memoir's voice: \(answer.text.prefix(120))")
                    answer = BrainAnswer(
                        text: Grounding.refusal, brain: kind,
                        citedCaptureIDs: [], latency: answer.latency
                    )
                } else if Grounding.isEcho(answer: answer.text, question: question) {
                    Log.shared.warn("\(kind.rawValue) echoed the question back, rejecting")
                    answer = await self.rejected(
                        answer, question: question, context: context,
                        instead: Grounding.refusal
                    )
                } else if !invented.isEmpty || !actions.isEmpty || !hosts.isEmpty || !durations.isEmpty {
                    var why: [String] = []
                    if !invented.isEmpty { why.append("figures \(invented.joined(separator: ", "))") }
                    if !actions.isEmpty { why.append("actions \(actions.joined(separator: ", "))") }
                    if !hosts.isEmpty { why.append("hosts \(hosts.joined(separator: ", "))") }
                    if !durations.isEmpty { why.append("durations \(durations.joined(separator: "; "))") }
                    Log.shared.warn("ungrounded answer from \(kind.rawValue): invented \(why.joined(separator: " and ")), rejecting")
                    // An invented ACTION is a claim about the user, so it gets the specific
                    // admission. Anything else falls back to the floor first.
                    answer = actions.isEmpty
                        ? await self.rejected(answer, question: question, context: context,
                                              instead: Grounding.refusal)
                        : BrainAnswer(text: Grounding.actionRefusal, brain: kind,
                                      citedCaptureIDs: [], latency: answer.latency)
                }
                return answer
            } catch {
                lastError = error
                availabilityCache[kind] = (false, Date())
                Log.shared.warn("\(kind.displayName) failed: \(error.localizedDescription). Falling back.")
            }
        }

        // The chain always ends in rulesOnly, which cannot fail, so this is close to unreachable.
        // If we are here the store itself is gone; say so rather than throwing an opaque error.
        Log.shared.error("Every brain failed: \(lastError?.localizedDescription ?? "no brains in chain").")
        throw MemoirError.brainUnavailable(.rulesOnly, "No brain could answer. Check the log for details.")
    }

    // MARK: - The floor

    /// The rules floor, over this router's store **and this router's clock**.
    ///
    /// Every `RulesOnlyBrain` this file needs comes through here, and that is the whole point.
    /// Six sites used to build it with `RulesOnlyBrain(store:)`, which takes the wall clock, so
    /// injecting a reference date anywhere else fixed retrieval and left rendering alone. One
    /// constructor means the two cannot drift apart again.
    private func floorBrain() -> RulesOnlyBrain {
        RulesOnlyBrain(store: store, now: now)
    }

    // MARK: - Deterministic answers

    /// The answers that are settled before a compound question is split into parts.
    ///
    /// Extracted from ``answer(question:context:category:)`` so that
    /// ``answerProgressively(question:context:category:onFloor:)`` cannot drift away from it.
    /// The split point matters: `hardRefusal` and `push` are checked on the WHOLE message,
    /// before ``QuestionRouter/parts(_:)`` sees it, and moving either one across that line
    /// changes what the router does.
    private static func settledBeforeSplitting(
        question: String,
        category: QuestionCategory?,
        reference: Date
    ) -> BrainAnswer? {
        // Some questions are refused deterministically, before retrieval and before any
        // model. Credentials are the reason this exists: asked for a GitHub password the
        // model answered "Your password for github is "login"", assembled from the text
        // around a login form. A grounding guard cannot defend against that, because a
        // guard only asks whether a claim is supported by the evidence.
        //
        // "Never reveal a credential" is a guarantee, and a guarantee cannot be delegated
        // to a classifier that is merely usually right.
        if let hard = Grounding.hardRefusal(for: question) {
            return BrainAnswer(text: hard, brain: .rulesOnly, citedCaptureIDs: [], latency: 0)
        }

        // A complaint is not a query. Searching its words is what produced "I don't have any
        // records of the URL https://t.co/ybIpXhYSsj" in reply to "this is not what I have
        // asked" - a URL the user never mentioned, proving Memoir was not listening twice over.
        if Grounding.isComplaint(question) {
            return BrainAnswer(text: Grounding.complaintRepair, brain: .rulesOnly,
                               citedCaptureIDs: [], latency: 0)
        }

        // A push is not a question, so no brain answers it.
        //
        // Returned as a PROPOSAL, never a write: CF-51 keeps parse and commit as two calls,
        // and the caller owns the accept. A phrase we could not parse says so plainly rather
        // than dropping what the user said on the floor.
        if category == .push {
            if let intent = PushParser.parse(question, reference: reference) {
                return BrainAnswer(text: Self.proposal(intent), brain: .rulesOnly,
                                   citedCaptureIDs: [], latency: 0)
            }
            return BrainAnswer(text: Grounding.unparsedPush, brain: .rulesOnly,
                               citedCaptureIDs: [], latency: 0)
        }

        return nil
    }

    /// The answers that are settled once the question is known to be a single part.
    ///
    /// Checked AFTER the compound split, because "hi and what did I do today" is a compound
    /// question that happens to start with a greeting, not a greeting.
    private static func settledAfterSplitting(
        question: String,
        category: QuestionCategory?
    ) -> BrainAnswer? {
        // Small talk is intercepted HERE, once, for every caller: the app, memoir-ask, and
        // anything else that calls the router. Putting this check in the app only meant
        // memoir-ask never saw it and kept spinning up a 3B model for "hi", which is exactly
        // the bug this fix was supposed to remove.
        //
        // Context is still assembled by the caller before this runs (cheap local SQL), but
        // this stops the expensive part (spinning up a 3B model and waiting out its cold
        // start) for a message that was never going to use that context anyway.
        let trimmed = question.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if RulesOnlyBrain.isSmallTalk(trimmed) {
            return BrainAnswer(text: RulesOnlyBrain.smallTalkReply(), brain: .rulesOnly,
                               citedCaptureIDs: [], latency: 0)
        }

        // Out-of-scope questions are refused here rather than after a round trip.
        //
        // "How much did I spend today" used to build 2000 tokens of context, wake the 3B
        // model, wait out its cold start, and only then produce a refusal, about twenty
        // seconds to say "I do not record that". The category is known before any of that
        // work starts, so none of it needs doing.
        if category == .outOfScope {
            return BrainAnswer(text: Grounding.outOfScopeRefusal, brain: .rulesOnly,
                               citedCaptureIDs: [], latency: 0)
        }

        return nil
    }

    // MARK: - Answering twice

    /// Answers twice: a grounded answer the caller can show at once, then the model's.
    ///
    /// The user was staring at nothing for twenty seconds. MEASURED on the real database,
    /// "what was that repo about screen memory": 24s total, of which 4.2s builds the context
    /// and ~20s is the on-device model. Almost all of that 20s is prefill of the context
    /// packet (1.6s with an empty prompt, 17.3s with 8 900 characters), so it cannot be
    /// warmed away, only waited out or covered. See `AppleOnDeviceBrain.WarmSession` for the
    /// full table, and for why prewarming is not the answer.
    ///
    /// So cover it. `rulesOnly` answers the same question straight from SQL and cannot invent,
    /// because it reads the store rather than writing prose about it. That answer goes to
    /// `onFloor` while the model is still working, and the model's phrasing replaces it when
    /// it lands. MEASURED end to end on the same database, same two questions:
    ///
    ///     what was that repo about screen memory   floor 4 849ms   final 20 448ms
    ///     where did I leave off                    floor 2 357ms   final 24 674ms
    ///
    /// The floor itself costs 2ms: it landed 2ms after the context packet was assembled in
    /// both cases. What the user waits for before seeing anything is retrieval, not the floor.
    /// Perceived latency drops from ~24s to under 5s without a single guard being relaxed.
    ///
    /// Three properties this promises, all of them asserted in `LatencyTests`:
    ///
    /// 1. **`onFloor` always runs before this returns.** Not "usually, because the model is
    ///    slow": the ordering is structural, so it holds against a fast brain too.
    /// 2. **The returned answer is the one from ``answer(question:context:category:)``,
    ///    unchanged.** Every guard (grounding, durations, hosts, actions, echo, tautology,
    ///    capitulation) runs exactly as before, and the final answer wins even when it is a
    ///    refusal and the floor was not. A fast wrong answer is worse than a slow right one,
    ///    and CF-17b does not get a fast path.
    /// 3. **If the model path fails outright, the floor is what the user keeps.** It has
    ///    already been shown; throwing it away to surface an error would take a real answer
    ///    off the screen.
    ///
    /// `onFloor` does not fire when there is nothing to bridge (small talk, a push proposal,
    /// a hard refusal, an out-of-scope question all return in single-digit milliseconds), nor
    /// when the floor has nothing worth saying. See ``groundedFloor(question:context:category:)``
    /// for where that bar sits and the one category it moves for.
    ///
    /// - Parameter onFloor: called at most once, synchronously, from inside the router, with
    ///   a grounded `rulesOnly` answer. Show it; expect to replace it. Keep it cheap: it runs
    ///   on the router's executor, so anything slow in there delays the model's answer too.
    public func answerProgressively(
        question: String,
        context: ContextPacket,
        category: QuestionCategory? = nil,
        onFloor: @escaping @Sendable (BrainAnswer) -> Void
    ) async throws -> BrainAnswer {
        // Nothing to bridge: these paths never reach a model, so a floor answer would only
        // flash a second sentence at the user on its way to the same result.
        if let settled = Self.settledBeforeSplitting(
            question: question, category: category, reference: now()) {
            return settled
        }
        if QuestionRouter.parts(question).count == 1,
           let settled = Self.settledAfterSplitting(question: question, category: category) {
            return settled
        }

        // The model starts FIRST, and the floor is computed while it runs. The obvious
        // ordering (floor, then model) would add the floor's ~1.5s to a wait that is
        // already 20s long. This way the floor costs the final answer nothing: it is SQLite
        // on the CPU while the model is prefilling on the neural engine.
        //
        // Reentrancy is what makes it work. `BrainRouter` is an actor, so the task below
        // cannot start until this one suspends, which it does immediately, awaiting the
        // floor. Ordering is still structural rather than racy: `onFloor` is called before
        // this function awaits the model at all.
        let final = Task { try await self.answer(question: question, context: context, category: category) }

        // Unstructured, so it would otherwise outlive a caller who gave up: the ask bar
        // closing on escape should not leave a generation running.
        return try await withTaskCancellationHandler {
            if let floor = await groundedFloor(question: question, context: context, category: category) {
                onFloor(floor)
                do {
                    return try await final.value
                } catch {
                    // The chain ends in `rulesOnly` and cannot normally fail, so being here
                    // means the store went away mid-answer. The floor is already on screen and
                    // is a real answer; replacing it with an error would be a downgrade.
                    Log.shared.warn("progressive answer failed after the floor landed, keeping the floor: \(error.localizedDescription)")
                    return floor
                }
            }
            return try await final.value
        } onCancel: {
            final.cancel()
        }
    }

    /// The floor's answer to this question, when it has one worth showing while the model works.
    ///
    /// `rulesOnly` is grounded by construction (it queries the store instead of describing
    /// it), so the CF-17b figure, host, action and duration guards have nothing to catch
    /// here, exactly as in ``answer(question:context:category:)`` where `rulesOnly` is
    /// exempted from all four. The echo check still applies, because a floor that hands the
    /// question back is noise whichever brain produced it.
    ///
    /// `answerIfSpecific` is the right bar for almost every question: the floor's general
    /// brief is an answer to nothing, and shown against "what was I doing in 1995" it implies
    /// a record that does not exist.
    ///
    /// `resumption` is the exception, and it is not a loophole. "Where did I leave off" is
    /// the one question whose honest answer IS the brief: "Recently in play: …", "Today:
    /// 1h 26m tracked, mostly in Chrome". Every line of it is computed from SQL rather than
    /// written about it. Without this, MEASURED on the real database, "where did I leave
    /// off" got no floor at all and the user watched nothing for 21.4s. It is also the
    /// safest place to relax the bar: the floor here is never the final answer unless the
    /// model has failed outright, and a true status brief beats an error.
    private func groundedFloor(
        question: String,
        context: ContextPacket,
        category: QuestionCategory?
    ) async -> BrainAnswer? {
        let floor = floorBrain()
        var grounded = await floor.answerIfSpecific(question: question, context: context, category: category)
        if grounded == nil, category == .resumption {
            grounded = try? await floor.answer(question: question, context: context)
        }
        guard let grounded,
              !grounded.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !Grounding.isEcho(answer: grounded.text, question: question) else {
            return nil
        }
        return grounded
    }

    /// Answers a challenge by checking the PREVIOUS question again, from the store.
    ///
    /// "are you sure?" carries no subject of its own. Answering it literally produces either
    /// a bluff ("Yes, I am sure.") or a shrug ("I do not have anything recorded about that"),
    /// and both are wrong for the same reason: the user is not asking a new question, they
    /// are asking Memoir to check the last one.
    ///
    /// So it re-runs the previous question through the floor, which reads the store directly
    /// and cannot bluff. If the figure survives, the user gets it again from a source that
    /// cannot flatter itself. If it does not, they were right to push back.
    private func recheck(_ answer: BrainAnswer, context: ContextPacket) async -> BrainAnswer {
        guard let previous = AskLog.shared.recent(limit: 1).first?.question,
              !previous.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return BrainAnswer(text: Grounding.refusal, brain: answer.brain,
                               citedCaptureIDs: [], latency: answer.latency)
        }
        let floor = floorBrain()
        guard let checked = await floor.answerIfSpecific(question: previous, context: context),
              !checked.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return BrainAnswer(text: Grounding.refusal, brain: answer.brain,
                               citedCaptureIDs: [], latency: answer.latency)
        }
        // Said plainly, so the user can see this is a second look rather than the same claim
        // repeated louder.
        return BrainAnswer(
            text: "I checked again from your session records.\n\n" + checked.text,
            brain: .rulesOnly, citedCaptureIDs: checked.citedCaptureIDs, latency: answer.latency
        )
    }

    /// What to say once a generative answer has been thrown away.
    ///
    /// Refusing outright was losing answers we genuinely had. Asked "what was I doing an
    /// hour ago" the model said "at 16:00" when the timeline said 16:49; the figure guard
    /// correctly rejected the invented time, and the user got "I do not have anything
    /// recorded about that", about an hour Memoir had a full record of. The guard was right
    /// and the outcome was still wrong.
    ///
    /// So a rejection falls to the floor rather than to silence. `rulesOnly` reads the store
    /// directly, so it is grounded by construction and cannot repeat the mistake. Only if it
    /// has nothing either do we actually refuse.
    private func rejected(
        _ answer: BrainAnswer,
        question: String,
        context: ContextPacket,
        instead refusal: String
    ) async -> BrainAnswer {
        // `answerIfSpecific`, not `answer`: the floor never says "I don't know", so asking
        // it for an answer always yields one. Its general brief ("6 open commitments,
        // 1 past due. Recently in play: …") was being returned as the reply to "what was I
        // doing in 1995", which is worse than a refusal because it implies a record that
        // does not exist. A fallback must be able to decline.
        let floor = floorBrain()
        if let grounded = await floor.answerIfSpecific(question: question, context: context),
           !grounded.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !Grounding.isEcho(answer: grounded.text, question: question) {
            Log.shared.info("fell back to rulesOnly after rejecting the generated answer")
            return BrainAnswer(
                text: grounded.text, brain: .rulesOnly,
                citedCaptureIDs: grounded.citedCaptureIDs, latency: answer.latency
            )
        }
        return BrainAnswer(
            text: refusal, brain: answer.brain, citedCaptureIDs: [], latency: answer.latency
        )
    }

    /// How a parsed push is shown back before anything is written.
    ///
    /// Plain and complete: the user has to be able to see a mis-parse at a glance, which
    /// means showing every field including the ones we did not fill in.
    static func proposal(_ intent: PushIntent) -> String {
        var lines = ["\(intent.kind == .commitment ? "Todo" : "Note"): \(intent.title)"]
        if let due = intent.dueAt {
            let fmt = DateFormatter()
            fmt.dateFormat = "EEE d MMM, HH:mm"
            lines.append("Due: \(fmt.string(from: due))")
        } else if intent.kind == .commitment {
            // Said explicitly rather than omitted, so an unnoticed missing date is impossible.
            lines.append("Due: no date given")
        }
        lines.append("")
        lines.append("Press return to save, or escape to discard.")
        return lines.joined(separator: "\n")
    }

    /// Raw completion over the same fallback chain, used by the extraction pipeline.
    ///
    /// Unlike ``answer(question:context:)`` this can throw, because a caller that wanted a model
    /// is better served by an explicit failure than by a template.
    public func complete(prompt: String, maxTokens: Int) async throws -> String {
        var lastError: (any Error)?
        for kind in chain() {
            guard let brain = makeBrain(kind) else { continue }
            guard await isAvailable(kind) else { continue }
            do {
                return try await brain.complete(prompt: prompt, maxTokens: maxTokens)
            } catch {
                lastError = error
                availabilityCache[kind] = (false, Date())
                Log.shared.warn("\(kind.displayName) completion failed: \(error.localizedDescription).")
            }
        }
        throw MemoirError.brainUnavailable(preferred, lastError?.localizedDescription ?? "No brain could complete the prompt.")
    }

    // MARK: - Chain

    /// The fallback order: preferred, then on-device, then rules only.
    ///
    /// Cloud brains never appear except as an explicitly chosen `preferred` with `allowCloud` on,
    /// which is what "never silently fall back to a cloud brain" means in code.
    func chain() -> [BrainKind] {
        var order: [BrainKind] = []
        if isAllowed(preferred) {
            order.append(preferred)
        } else if !loggedCloudBlock {
            loggedCloudBlock = true
            let why = preferred.isCloud ? "cloud use is off" : "network model use is off"
            Log.shared.warn("\(preferred.displayName) is blocked because \(why). Using local brains.")
        }
        for fallback in [BrainKind.appleOnDevice, .rulesOnly] where !order.contains(fallback) {
            order.append(fallback)
        }
        return order
    }

    /// Whether a brain may be used at all under the current privacy settings.
    ///
    /// Two switches, not one. `allowCloud` covers the third parties; `allowLocalNetwork`
    /// covers the model on the user's own network, which is not "cloud" but still leaves
    /// this Mac. Everything that reaches the network is behind one of them, which is what
    /// makes "with the default settings, nothing leaves" checkable rather than asserted.
    func isAllowed(_ kind: BrainKind) -> Bool {
        if kind.isCloud { return config.allowCloud }
        if kind == .localNetwork { return config.allowLocalNetwork }
        return true
    }

    /// Position in the display order, most private first.
    private func rank(_ kind: BrainKind) -> Int {
        switch kind {
        case .appleOnDevice: return 0
        case .rulesOnly: return 1
        // Between on-device and cloud, which is exactly where it sits on privacy: your own
        // machine, but not this one.
        case .localNetwork: return 2
        case .claudeCode: return 3
        case .anthropicAPI: return 4
        }
    }

    /// Cached availability probe.
    private func isAvailable(_ kind: BrainKind) async -> Bool {
        guard isAllowed(kind) else { return false }
        if let cached = availabilityCache[kind], Date().timeIntervalSince(cached.checkedAt) < Self.availabilityTTL {
            return cached.value
        }
        guard let brain = makeBrain(kind) else {
            availabilityCache[kind] = (false, Date())
            return false
        }
        let value = await brain.isAvailable()
        availabilityCache[kind] = (value, Date())
        return value
    }

    /// Builds a brain instance for a kind, or nil when it cannot be constructed
    /// (no API key, cloud disallowed).
    private func makeBrain(_ kind: BrainKind) -> (any Brain)? {
        guard isAllowed(kind) else { return nil }
        if let brainFactory { return brainFactory(kind) }
        switch kind {
        case .appleOnDevice:
            return AppleOnDeviceBrain()
        case .rulesOnly:
            return floorBrain()
        case .localNetwork:
            // Only when the user has configured a host. There is no default endpoint and
            // never will be: a brain that reaches a machine the user did not name is exactly
            // the surprise this tier exists to avoid.
            guard let endpoint = config.localNetworkEndpoint else { return nil }
            return LocalNetworkBrain(endpoint: endpoint)
        case .claudeCode:
            return ClaudeCodeBrain(binaryPath: config.claudeCodePath)
        case .anthropicAPI:
            guard let key = cachedAnthropicKey(), !key.isEmpty else { return nil }
            return AnthropicBrain(apiKey: key, model: config.anthropicModel)
        }
    }

    /// The API key, from the config if it was injected, otherwise from the Keychain, cached.
    private func cachedAnthropicKey() -> String? {
        if let cached = keyCache { return cached }
        let loaded = BrainKeychain.load()
        keyCache = .some(loaded)
        return loaded
    }
}
