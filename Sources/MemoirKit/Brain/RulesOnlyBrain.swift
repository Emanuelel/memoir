import Foundation

/// The guaranteed floor: answers assembled from the store with no model of any kind.
///
/// It is always available, it never sends anything anywhere, and it always returns something.
/// Every other brain can be off, missing, throttled or offline and Memoir still answers.
///
/// It recognises four shapes of question and renders a template for each:
/// open commitments, today's apps and time spent, "what do you know about X", and a general brief.
public struct RulesOnlyBrain: Brain {
    /// The memory this brain reads. Read-only use: it never mutates the store.
    private let store: Store

    /// The clock every template reads. "Today", "overdue" and "due tomorrow" are all decided
    /// by it, so it is the one thing in this type that has to be injectable: an integration
    /// test seeds a fixed day and would otherwise be asking about the day it happens to run.
    private let clock: @Sendable () -> Date

    /// Where the user's names come from. CF-61 filters parsed messages by sender, and the
    /// comparison has to be against the same identity the extractor uses, read at answer
    /// time because onboarding fills it in after launch. Injectable for the same reason the
    /// clock is: `UserNames.install` is process-global, and a test that wrote it would leak
    /// into whatever suite happens to be running alongside.
    private let names: @Sendable () -> UserNames

    /// Creates the brain over an existing store.
    public init(store: Store) {
        self.init(store: store, now: { Date() })
    }

    /// Creates the brain with an injected clock. Not `public`: the app always wants the real
    /// one, the integration suite never does.
    init(
        store: Store,
        now: @escaping @Sendable () -> Date,
        names: @escaping @Sendable () -> UserNames = { .current }
    ) {
        self.store = store
        self.clock = now
        self.names = names
    }

    /// Always `.rulesOnly`.
    public var kind: BrainKind { .rulesOnly }

    /// Always `true`. This brain has no dependencies beyond the database.
    public func isAvailable() async -> Bool { true }

    /// Explains the current state for the settings UI.
    public func availabilityDetail() async -> String {
        "No model. Answers are assembled from your memory on this Mac and always work."
    }

    // MARK: - Brain

    /// Answers by template. Never throws in practice: storage failures degrade to a plain message.
    public func answer(question: String, context: ContextPacket) async throws -> BrainAnswer {
        let started = Date()
        let rendered = await compose(question: question, context: context, now: clock())
        return BrainAnswer(
            text: rendered.text,
            brain: .rulesOnly,
            citedCaptureIDs: rendered.captureIDs,
            latency: Date().timeIntervalSince(started)
        )
    }

    /// The floor's answer, or nil when it would only recite the general brief.
    ///
    /// Used when a generated answer has been rejected and we need a grounded replacement.
    /// The floor cannot invent, which is exactly why it is the right fallback, but it also
    /// never says "I don't know", and its general brief would be offered as the reply to
    /// questions it does not address. Asked "what was I doing in 1995" the fallback read
    /// "6 open commitments, 1 past due. Recently in play: …", which is worse than a refusal
    /// because it implies a record of 1995 that does not exist.
    ///
    /// - Returns: nil when the honest outcome is a refusal rather than a status report.
    /// - Parameter category: the routed category, when the caller has one. The floor
    ///   runs its own keyword classifier, and where the two disagree the router wins:
    ///   a question routed as `recall` must not be answered with a resumption timeline
    ///   just because its wording looked like one. Nil keeps the floor's own judgement,
    ///   which is what the plain `answer` path wants.
    public func answerIfSpecific(
        question: String,
        context: ContextPacket,
        category: QuestionCategory? = nil
    ) async -> BrainAnswer? {
        let started = Date()
        let rendered = await compose(question: question, context: context, now: clock(), category: category)
        guard !rendered.isGeneralBrief else { return nil }
        return BrainAnswer(
            text: rendered.text,
            brain: .rulesOnly,
            citedCaptureIDs: rendered.captureIDs,
            latency: Date().timeIntervalSince(started)
        )
    }

    /// Refuses. This brain has no model, and completion is not a question.
    ///
    /// It used to treat the prompt as a question and return its template answer, which reads as
    /// harmless and is not. `complete` has exactly one caller (``LLMExtractor``, through
    /// ``BrainRouter/complete(prompt:maxTokens:)``), and it wants JSON. Returning prose meant the
    /// router's fallback chain silently converted *the model failed* into *the model answered
    /// something unparseable*, which is a different and much quieter thing.
    ///
    /// The case that exposed it: a laptop with a saved API key, offline. `AnthropicBrain`
    /// reports available because a key is non-empty, the request fails, the chain falls past an
    /// absent on-device model to here, and extraction gets a templated paragraph about the
    /// user's commitments. It parses as nothing, is discarded, and looks exactly like a quiet
    /// day, for as long as the machine is offline.
    ///
    /// Throwing instead lets the router exhaust its chain and report honestly, so the extractor
    /// logs a real failure and moves on to guided generation. Answering is untouched: this brain
    /// remains the floor for ``answer(question:context:)`` and always will be.
    public func complete(prompt: String, maxTokens: Int) async throws -> String {
        throw MemoirError.brainUnavailable(
            .rulesOnly, "the rules-only brain has no model and cannot complete a prompt.")
    }

    // MARK: - Intent

    /// The question shapes this brain understands.
    enum Intent: Equatable {
        case commitments
        case today
        /// "what was the last site" - a SORT, not a search.
        ///
        /// Handed a correctly ordered list starting with Gmail, the model answered "Google
        /// Maps", which appeared nowhere in it. Asking a 3B model to pick the first item from
        /// a list it was just given is a job with nothing to gain and a whole class of
        /// invention to lose. So this one is computed and never generated.
        case mostRecent
        /// "what did I write on whatsapp" - a FILTER over parsed messages, not a brief.
        ///
        /// This question fell through to the general brief and was answered with "10 open
        /// commitments. Recently in play: ..." - a status report, and an answer to no
        /// question. Sender attribution in the reply must come from `MessageParser`, which
        /// reads senders off the screen, so this one is computed and never generated.
        case myMessages
        case lookup(String)
        case resumption
        case accounting(AccountingAsk)
        case smallTalk
        case brief
    }

    /// What an accounting question is actually asking for.
    ///
    /// "The numbers were accurate but the answer ignored the question" is the eval
    /// verdict this type exists to fix. One whole-day app table was the reply to four
    /// different questions; each now gets its own arithmetic.
    enum AccountingAsk: Equatable {
        /// "how much time did I spend in chrome": one app's figure, not the table.
        case appTime
        /// "how long have I been working": the total, with first and last activity.
        case total
        /// "what did I ship today": where the time went, by project, with evidence.
        case shipped
        /// "summarise my day": the full picture.
        case summary
        /// "timesheet" / "invoice": the per-day, per-project record with evidence.
        case timesheet
        /// "weekly review": time, what surfaced, what is owed.
        case review
    }

    /// Greetings and chit-chat that are not asking the memory for anything.
    ///
    /// Without this, "hey how's going" fell through to .brief and produced a full status
    /// dump (commitments, projects, hours tracked) as the answer to a hello. A greeting
    /// deserves a greeting.
    public static func isSmallTalk(_ q: String) -> Bool {
        let greetings = [
            "hey", "hi", "hello", "how's it going", "hows it going", "how is it going",
            "how are you", "how's going", "hows going", "what's up", "whats up", "sup",
            "good morning", "good afternoon", "good evening", "yo",
        ]
        let stripped = q.trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "?!. "))
        return greetings.contains(stripped) || greetings.contains { stripped.hasPrefix($0 + " ") }
    }

    /// True when the question asks for the single most recent thing.
    ///
    /// Narrow on purpose: "what was the last site" is a superlative, "what was I doing" is a
    /// summary, and only the first has exactly one right answer sitting at the top of a list.
    public static func asksForMostRecent(_ question: String) -> Bool {
        let q = " " + question.lowercased()
            .replacingOccurrences(of: "'", with: "")
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined(separator: " ") + " "
        let phrases = ["last site", "last website", "last page", "last tab", "last app",
                       "latest site", "latest website", "latest page",
                       "visit last", "visited last", "looking at last", "was i looking at",
                       "most recent page", "most recent site", "most recent thing",
                       "last thing i", "what was i just on", "where was i just"]
        return phrases.contains { q.contains(" " + $0 + " ") || q.contains(" " + $0) }
    }

    /// Classifies a question by keyword. Deliberately dumb and deliberately predictable.
    static func classify(_ question: String) -> Intent {
        let q = question.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return .brief }

        // The canonical forms first, exactly. QueryRewriter normalises "catch me up", "where
        // was I" and "pick me up where I left off" into one string precisely so this layer
        // stops guessing from wording, and it would be absurd for the layer to then guess at
        // the canonical form too. A closed set deserves an exact match.
        // The user's own messages are a filter over the parse. Checked before the
        // superlative, because "the last thing I sent" is both shapes at once and the
        // messages reading is the one that was asked.
        if Self.asksForMyMessages(q) { return .myMessages }
        // A superlative asks for the top of a sorted list. Answer it from the list.
        if Self.asksForMostRecent(q) { return .mostRecent }

        switch q {
        case QueryRewriter.Canonical.openCommitments.rawValue.lowercased(): return .commitments
        case QueryRewriter.Canonical.recentActivity.rawValue.lowercased(): return .today
        case QueryRewriter.Canonical.timeToday.rawValue.lowercased(): return .today
        default: break
        }

        if Self.isSmallTalk(q) { return .smallTalk }
        if let ask = accountingAsk(in: q) { return .accounting(ask) }

        // Resumption before lookup: "catch me up" is a lookup lead, so without this
        // check "catch me up on what I was doing" became a lookup for the subject
        // "what i was doing", a search for nothing. A concrete subject still wins:
        // "catch me up on fenwick" is a lookup about fenwick.
        let subj = subject(in: q)
        if isResumptionCue(q), subj == nil || subj!.hasPrefix("what") { return .resumption }
        if let subject = subj { return .lookup(subject) }

        let commitmentWords = [
            "commitment", "commitments", "owe", "i owe", "promised", "promise",
            "todo", "to-do", "to do", "task", "tasks", "due", "deadline",
            "follow up", "follow-up", "on my plate", "outstanding", "chase",
        ]
        if commitmentWords.contains(where: { q.contains($0) }) { return .commitments }

        let todayWords = [
            "today", "so far", "this morning", "this afternoon", "time spent",
            "how long", "where did my time", "what have i been", "what did i do",
            "what am i working on", "been working on", "busy with",
        ]
        if todayWords.contains(where: { q.contains($0) }) { return .today }

        return .brief
    }

    /// True when the question is asking to reload state rather than look something up.
    static func isResumptionCue(_ q: String) -> Bool {
        let cues = [
            "where did i leave off", "where was i", "left off", "leave off",
            "pick up where", "get me back to", "before i stopped", "catch me up",
            "what was i doing", "what was i working on", "what did i look at most recently",
            "most recently", "last thing i", "what was i on", "an hour ago",
        ]
        return cues.contains { q.contains($0) }
    }

    /// The accounting sub-intent, or nil when the question is not accounting-shaped.
    static func accountingAsk(in q: String) -> AccountingAsk? {
        let timesheet = ["timesheet", "time sheet", "invoice", "billable"]
        if timesheet.contains(where: { q.contains($0) }) { return .timesheet }
        let review = ["weekly review", "week in review", "review my week", "review of my week",
                      "what did i do this week", "summarise my week", "summarize my week"]
        if review.contains(where: { q.contains($0) }) { return .review }
        let shipped = ["what did i ship", "what did i get done", "what did i accomplish",
                       "what did i actually do"]
        if shipped.contains(where: { q.contains($0) }) { return .shipped }
        let summary = ["summarise my day", "summarize my day", "recap my day",
                       "sum up my day", "how was my day", "what did i do today"]
        if summary.contains(where: { q.contains($0) }) { return .summary }
        let total = ["how long have i been working", "how long was i working",
                     "how many hours", "how long have i worked"]
        if total.contains(where: { q.contains($0) }) { return .total }
        let time = ["how much time", "time did i spend", "time spent",
                    "how long was i in", "how long did i spend", "how long in"]
        if time.contains(where: { q.contains($0) }) { return .appTime }
        return nil
    }

    /// True when the question asks for the user's own sent messages.
    ///
    /// "what did I write on whatsapp" fell through to the general brief ("10 open
    /// commitments. Recently in play: ...") - true, and no answer at all. Same cure as the
    /// superlative above: recognise the shape exactly and answer it from the store.
    ///
    /// Narrow on purpose, in three ways. "write down a note" is an instruction, not a
    /// question, so the note-taking verbs bail out first. "what did I say I would do" is a
    /// commitments question wearing message words, so a promise tail bails out too. And a
    /// question that names a non-chat surface ("what did I write in the doc") is about the
    /// doc: it only fires when a messaging surface is named, or no surface at all.
    public static func asksForMyMessages(_ question: String) -> Bool {
        let q = " " + question.lowercased()
            .replacingOccurrences(of: "'", with: "")
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined(separator: " ") + " "

        // "write down a note", "write a summary", "write me an email": asking Memoir to
        // produce text, never asking what the user already sent. ("i would" and the bare
        // "id" are what is left of "I would" / "I'd" after apostrophes are stripped.)
        let stops = ["write down ", "write a ", "write an ", "write up ", "write me ",
                     "wrote down ", "i would ", "id "]
        if stops.contains(where: { q.contains(" " + $0) }) { return false }

        let phrases = ["what did i write", "what did i send", "what did i say",
                       "what have i written", "what have i sent", "what i wrote",
                       "my last message", "my last messages", "my recent messages",
                       "messages i sent", "message i sent", "messages i wrote",
                       "last thing i wrote", "last thing i sent", "last thing i said"]
        guard phrases.contains(where: { q.contains(" " + $0 + " ") || q.contains(" " + $0) }) else {
            return false
        }

        // A named messaging surface settles it.
        let chatSurfaces = ["whatsapp", "telegram", "slack", "discord", "gmail", "imessage",
                            "message", "messages", "chat", "chats", "dm", "dms"]
        if chatSurfaces.contains(where: { q.contains(" " + $0 + " ") }) { return true }

        // A named non-chat surface means a different question entirely. No surface at all
        // ("what did I write to Marco") stays a messages question.
        let otherSurfaces = ["doc", "docs", "document", "documents", "note", "notes",
                             "notion", "file", "files", "essay", "post", "draft", "page",
                             "readme", "wiki", "journal", "code"]
        return !otherSurfaces.contains { q.contains(" " + $0 + " ") }
    }

    /// Pulls the subject out of a lookup-shaped question, e.g. "who is marco" -> "marco".
    static func subject(in loweredQuestion: String) -> String? {
        let leads = [
            "what do you know about ", "what do i know about ", "anything on ", "anything about ",
            "tell me about ", "remind me about ", "remind me of ", "what about ",
            "who is ", "who's ", "whos ", "look up ", "lookup ", "details on ", "info on ",
            "catch me up on ", "context on ", "background on ",
        ]
        for lead in leads {
            guard let range = loweredQuestion.range(of: lead) else { continue }
            let tail = String(loweredQuestion[range.upperBound...])
            let cleaned = tail.trimmingCharacters(in: CharacterSet(charactersIn: " ?.!,;:'\"()[]"))
            if cleaned.count >= 2 { return cleaned }
        }
        return nil
    }

    // MARK: - Composition

    /// Text plus the captures it was derived from.
    struct Rendered {
        var text: String
        var captureIDs: [ID]
        /// True when this is the general brief rather than a reply to what was asked.
        ///
        /// The floor always produces *something*, which is the point of a floor, but
        /// "6 open commitments, 1 past due. Recently in play: …" is an answer to no
        /// question. Offered as a fallback for "what was I doing in 1995" it is worse than
        /// silence, because it implies a record that does not exist.
        var isGeneralBrief: Bool = false
    }

    /// Routes to the right template and appends the "no model" footer.
    func compose(
        question: String,
        context: ContextPacket,
        now: Date,
        category: QuestionCategory? = nil
    ) async -> Rendered {
        // Out of scope is refused here too, not only in `BrainRouter`.
        //
        // The floor's own classifier has no notion of scope: every question it sees is
        // matched against the four shapes it can render, and the nearest one wins even when
        // the honest answer is that there is no shape. Asked "what did I have for lunch" it
        // matched nothing, took the canonical rewrite it had been handed, and rendered
        // today's app table. Nothing in that answer is false and none of it was asked for,
        // which is the failure mode a refusal exists to prevent.
        //
        // `BrainRouter` already refuses before any brain runs, so this is the second lock on
        // the same door: for `answerIfSpecific`, for the MCP server, and for whatever calls
        // the floor next.
        if category == .outOfScope {
            return Rendered(text: Grounding.outOfScopeRefusal + "\n\n" + Self.footer, captureIDs: [])
        }

        var rendered: Rendered
        var intent = Self.classify(question)

        // The router outranks the floor's keyword guess. "Where was I" reads as
        // resumption to the keywords, but if it was routed as recall then a timeline is
        // not what was asked for, and offering one would put a status report in the
        // place of an answer, the failure `isGeneralBrief` exists to prevent.
        if let category, category != .resumption, intent == .resumption {
            intent = .brief
        }

        // "my last messages on whatsapp" names an app and carries "last", which is exactly
        // the shape `appActivity` answers with window titles. It asks what the user WROTE,
        // not what was open, so the messages intent is decided first.
        if Self.asksForMyMessages(question) {
            rendered = await renderMyMessages(now: now)
            if rendered.captureIDs.isEmpty { rendered.captureIDs = context.captureIDs }
            rendered.text = rendered.text.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n" + Self.footer
            return rendered
        }

        // Accounting questions never take the app-activity shortcut: "how much time
        // did I spend in chrome" matched the activity words and answered with window
        // titles: accurate, and not the question. Arithmetic goes to arithmetic.
        let wantsArithmetic: Bool
        switch intent {
        case .accounting, .resumption: wantsArithmetic = true
        default: wantsArithmetic = false
        }
        if !wantsArithmetic, let app = await appActivity(question: question, now: now) {
            rendered = app
            if rendered.captureIDs.isEmpty { rendered.captureIDs = context.captureIDs }
            rendered.text = rendered.text.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n" + Self.footer
            return rendered
        }
        switch intent {
        case .commitments: rendered = await renderCommitments(now: now)
        case .today: rendered = await renderToday(now: now)
        case .lookup(let subject): rendered = await renderLookup(subject: subject, now: now)
        case .resumption: rendered = await renderResumption(question: question, now: now)
        case .accounting(let ask): rendered = await renderAccounting(ask: ask, question: question, now: now)
        case .smallTalk: rendered = Rendered(text: Self.smallTalkReply(), captureIDs: [])
        case .mostRecent: rendered = await renderMostRecent(now: now)
        case .myMessages: rendered = await renderMyMessages(now: now)
        case .brief: rendered = await renderBrief(question: question, now: now)
        }

        if rendered.captureIDs.isEmpty { rendered.captureIDs = context.captureIDs }
        rendered.text = rendered.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if rendered.text.isEmpty {
            rendered.text = "I have not recorded anything about that yet."
        }

        // A question about recent activity, answered from a record that stops hours short
        // of now, is answered wrongly however good the retrieval is. Say the gap first:
        // the answer below is still true about the past, and the user can act on the gap.
        if Self.needsFreshRecord(intent) {
            // The later of the two: a session with no readable text still proves the
            // product was awake and watching, and a store seeded with sessions alone is
            // not blind.
            let stats = await safe(nil as StoreStats?) { try await store.stats() }
            let newest = [stats?.newestCapture, stats?.newestSession].compactMap { $0 }.max()
            if let note = Self.stalenessNote(newest: newest, now: now) {
                rendered.text = note + "\n\n" + rendered.text
            }
        }

        rendered.text += "\n\n" + Self.footer
        return rendered
    }

    /// Whether an answer of this shape is about the present, and so is wrong if the
    /// record has stopped. A lookup about a person is not; "what did I just do" is.
    /// Whether a question of this wording is about the present, and so is answered
    /// wrongly if the record has stopped. The live probe asks this without needing to
    /// know anything about how intents are represented.
    public static func questionIsAboutNow(_ question: String) -> Bool {
        needsFreshRecord(classify(question))
    }

    static func needsFreshRecord(_ intent: Intent) -> Bool {
        switch intent {
        case .today, .resumption, .mostRecent, .myMessages, .accounting: return true
        case .commitments, .lookup, .smallTalk, .brief: return false
        }
    }

    /// Shown on every answer so the user always knows no model was involved.
    /// How stale the record may be before an answer about "recent" must confess it.
    ///
    /// Capture normally writes every few seconds while the user is at the machine, so a
    /// gap this long means it has stopped: paused, crashed, or (the common one) the
    /// Accessibility grant was invalidated by a rebuild and never re-given.
    public static let stalenessThreshold: TimeInterval = 30 * 60

    /// A line to put ABOVE an answer when the record stops well short of now.
    ///
    /// This is the failure that made every other failure look worse than it was. Capture
    /// had been dead for eighteen hours; asked what the last message was, Memoir answered
    /// confidently from the day before and said nothing about the gap. The user concluded
    /// the product talked nonsense. It was not wrong about the past; it was silent about
    /// the present, which is worse, because a stated gap is a thing you can go and fix.
    ///
    /// - Returns: nil when the record reaches close enough to now to be trusted.
    static func stalenessNote(newest: Date?, now: Date) -> String? {
        guard let newest else {
            return "**I have not captured anything yet.** Check that Memoir is running and has Accessibility permission (System Settings → Privacy & Security → Accessibility)."
        }
        let gap = now.timeIntervalSince(newest)
        guard gap > stalenessThreshold else { return nil }
        return """
            **Nothing has been captured since \(timeText(newest, now: now)) (\(formatDuration(gap)) ago).** \
            Anything after that is missing from this answer. Memoir may be paused or quit, or the \
            Accessibility permission may have been invalidated by a rebuild (System Settings → \
            Privacy & Security → Accessibility).
            """
    }

    /// Where the answer came from, and nothing about what else was or was not running.
    ///
    /// This used to read "No model is running", which the floor is not entitled to say. It
    /// is reached in two very different situations: no model installed at all, and a model
    /// that ran and whose reply was rejected or bettered. It cannot tell them apart, and
    /// asserting the first told a user with a configured, available, just-attempted model
    /// that no model was running. They reasonably concluded the product was broken.
    public static let footer = "Answered straight from your records on this Mac."


    // MARK: - App activity

    /// Answers "what was I looking at in <app>" from window titles.
    ///
    /// Window titles are the single most reliable signal available: an Electron app may
    /// expose almost no content through the accessibility tree, but its title is always
    /// there. Returns nil when the question is not about a specific app, so the normal
    /// classifier still runs.
    private func appActivity(question: String, now: Date) async -> Rendered? {
        let q = question.lowercased()

        // Only answer when the question is actually about what was on screen.
        let activityWords = [
            "looking at", "look at", "was i on", "were on", "open", "opened", "reading",
            "last", "recent", "recently", "page", "file", "document", "note", "tab",
            "window", "doing in", "working on in", "viewing", "viewed", "in ",
        ]
        guard activityWords.contains(where: { q.contains($0) }) else { return nil }

        let since = now.addingTimeInterval(-60 * 60 * 24 * 14)
        let captures = await safe([CaptureEvent]()) { try await store.captures(since: since, limit: 4000) }
        guard !captures.isEmpty else { return nil }

        // Match the question against app names we have actually seen.
        var best: (name: String, score: Int)? = nil
        for name in Set(captures.map(\.appName)) {
            let needle = name.lowercased()
            let compact = needle.replacingOccurrences(of: " ", with: "")
            let hit = q.contains(needle) || (compact.count > 3 && q.contains(compact))
            guard hit else { continue }
            if best == nil || needle.count > best!.score { best = (name, needle.count) }
        }
        guard let appName = best?.name else { return nil }

        let mine = captures.filter { $0.appName == appName }.sorted { $0.ts > $1.ts }
        guard let latest = mine.first else { return nil }

        // Distinct titles, most recent first.
        var seen = Set<String>()
        var recent: [(title: String, ts: Date, id: ID)] = []
        for c in mine {
            guard let title = c.windowTitle, !title.isEmpty else { continue }
            let key = title.lowercased()
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            recent.append((title, c.ts, c.id))
            if recent.count >= 6 { break }
        }

        guard !recent.isEmpty else {
            return Rendered(
                text: "You were in \(appName) at \(Self.timeText(latest.ts, now: now)), but I have no window titles for it. Turn on Screen Recording in Settings if you want Memoir to record what was open.",
                captureIDs: [latest.id]
            )
        }

        var lines = ["The last thing open in \(appName) was **\(recent[0].title)** (\(Self.timeText(recent[0].ts, now: now)))."]
        if recent.count > 1 {
            lines.append("")
            lines.append("Before that:")
            for r in recent.dropFirst() {
                lines.append("- \(r.title) · \(Self.timeText(r.ts, now: now))")
            }
        }
        return Rendered(text: lines.joined(separator: "\n"), captureIDs: recent.map(\.id))
    }

    /// "14:32" today, otherwise "Tue 14:32".
    static func timeText(_ ts: Date, now: Date) -> String {
        let cal = Calendar.current
        if cal.isDate(ts, inSameDayAs: now) {
            return ts.formatted(.dateTime.hour().minute())
        }
        return ts.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }

    // MARK: - Templates

    /// Open commitments, soonest first, overdue at the top.
    private func renderCommitments(now: Date) async -> Rendered {
        // Provisional rows are kept in memory and never asserted as promises.
        let all = await safe([Entity]()) { try await store.entities(kind: .commitment, includeDeleted: false) }
            .filter { !$0.provisional }
        let open = all.filter { !$0.deleted }
        guard !open.isEmpty else {
            return Rendered(text: "Nothing is on your plate that I have picked up on. No open commitments in memory.", captureIDs: [])
        }

        let sorted = open.sorted { a, b in
            switch (a.dueAt, b.dueAt) {
            case let (l?, r?): return l < r
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return a.updatedAt > b.updatedAt
            }
        }

        let overdue = sorted.filter { ($0.dueAt.map { $0 < now }) == true }
        var lines: [String] = []
        let header = overdue.isEmpty
            ? "\(sorted.count) open \(sorted.count == 1 ? "commitment" : "commitments"):"
            : "\(sorted.count) open, \(overdue.count) already past due:"
        lines.append(header)

        for entity in sorted.prefix(12) {
            let due = Self.dueDescription(entity.dueAt, now: now)
            let pin = entity.pinned ? " (pinned)" : ""
            let head = Self.oneLine(entity.title) + pin
            lines.append("- \(head)\(Self.sentenceEnd(head)) \(due).")
        }
        if sorted.count > 12 {
            lines.append("and \(sorted.count - 12) more.")
        }
        return Rendered(text: lines.joined(separator: "\n"), captureIDs: [])
    }

    /// A day's apps and time, grouped by what the work was about, plus the last few
    /// things that were on screen. Defaults to today; accounting can point it at any day.
    private func renderToday(
        now: Date,
        windowStart: Date? = nil,
        windowEnd: Date? = nil,
        windowLabel: String = "today"
    ) async -> Rendered {
        let dayStart = windowStart ?? Calendar.current.startOfDay(for: now)
        let dayEnd = windowEnd ?? now
        let sessions = WorkSpanBuilder.clip(
            await safe([Session]()) { try await store.sessions(from: dayStart, to: dayEnd) },
            from: dayStart, to: dayEnd
        )
        let recent = await safe([CaptureEvent]()) { try await store.captures(from: dayStart, to: dayEnd, limit: 200) }

        var lines: [String] = []

        let active = sessions.filter { !$0.idle && $0.duration > 0 }
        if active.isEmpty {
            lines.append("I have not tracked any app time \(windowLabel) yet.")
        } else {
            var byApp: [String: TimeInterval] = [:]
            for session in active {
                byApp[session.appName, default: 0] += session.duration
            }
            let total = byApp.values.reduce(0, +)
            let ranked = byApp.sorted { $0.value > $1.value }
            lines.append("\(Self.formatDuration(total)) tracked \(windowLabel) across \(byApp.count) \(byApp.count == 1 ? "app" : "apps"):")
            for (app, seconds) in ranked.prefix(6) {
                lines.append("- \(app): \(Self.formatDuration(seconds))")
            }
            if ranked.count > 6 {
                lines.append("and \(ranked.count - 6) more.")
            }
            let idle = sessions.filter(\.idle).reduce(0) { $0 + $1.duration }
            if idle > 60 {
                lines.append("Away from the keyboard for about \(Self.formatDuration(idle)).")
            }

            // The same time, cut by what it was for. Only rendered when the ontology
            // actually recognised something: an all-app-fallback list would just
            // repeat the table above under a different heading.
            let found = await spans(from: dayStart, to: dayEnd)
            if found.contains(where: { $0.entityID != nil }) {
                lines.append("")
                lines.append("Where it went:")
                lines.append(contentsOf: Self.spanLines(found, limit: 5))
            }
        }

        let titles = recent.compactMap { $0.windowTitle }
            .map { Self.oneLine($0) }
            .filter { !$0.isEmpty }
        var seen = Set<String>()
        let distinctTitles = titles.filter { seen.insert($0).inserted }
        if !distinctTitles.isEmpty {
            lines.append("")
            lines.append("Most recently on screen:")
            for title in distinctTitles.prefix(5) {
                lines.append("- \(String(title.prefix(90)))")
            }
        }

        let touched = await safe([Entity]()) { try await store.entities(kind: nil, includeDeleted: false) }
            .filter { $0.updatedAt >= dayStart }
        if !touched.isEmpty {
            lines.append("")
            lines.append("Picked up today: " + touched.prefix(6).map { Self.oneLine($0.title) }.joined(separator: ", ") + ".")
        }

        return Rendered(text: lines.joined(separator: "\n"), captureIDs: Array(recent.prefix(5).map(\.id)))
    }

    /// "Here is what I know about X", from entities first and raw captures second.
    private func renderLookup(subject: String, now: Date) async -> Rendered {
        let entities = await safe([Entity]()) { try await store.searchEntities(subject, limit: 8) }
            .filter { !$0.deleted }
        let captures = await safe([CaptureEvent]()) { try await store.searchCaptures(subject, limit: 5) }

        guard !entities.isEmpty || !captures.isEmpty else {
            return Rendered(
                text: "Nothing in memory about \"\(subject)\". Either it has not been on screen while Memoir was running, or the app it was in is on your exclusion list.",
                captureIDs: []
            )
        }

        var lines: [String] = ["Here is what I have on \"\(subject)\"."]

        if !entities.isEmpty {
            lines.append("")
            for entity in entities.prefix(6) {
                var line = "- \(entity.kind.displayName): \(Self.oneLine(entity.title))"
                if entity.kind == .commitment {
                    line += " (\(Self.dueDescription(entity.dueAt, now: now)))"
                }
                if let detail = entity.detail, !detail.isEmpty {
                    line += ". " + String(Self.oneLine(detail).prefix(160))
                }
                if entity.corrected { line += " [your correction]" }
                lines.append(line)
            }
        }

        if !captures.isEmpty {
            lines.append("")
            lines.append("Seen in:")
            for capture in captures.prefix(4) {
                let when = capture.ts.formatted(date: .abbreviated, time: .shortened)
                let snippet = Self.snippet(from: capture.text, around: subject)
                lines.append("- \(capture.appName), \(when): \(snippet)")
            }
        }

        return Rendered(text: lines.joined(separator: "\n"), captureIDs: captures.map(\.id))
    }

    /// The catch-all: a short state of the world so the answer is never empty.
    /// A short, human reply to a greeting. No model, no memory dump, no footer needed:
    /// answering "hi" with a report is the exact failure this exists to prevent.
    public static func smallTalkReply() -> String {
        ["Doing alright. What can I help you dig up?",
         "All good here. What are you after?",
         "Ticking along. What do you need?"].randomElement()!
    }

    /// The single most recent thing that was on screen, read straight off the timeline.
    ///
    /// No model, so nothing to invent. The answer is a row that exists, or an honest nothing.
    private func renderMostRecent(now: Date) async -> Rendered {
        let recent = await safe([CaptureEvent]()) {
            try await store.captures(since: now.addingTimeInterval(-60 * 60 * 24 * 3), limit: 400)
        }
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm"
        for capture in recent.sorted(by: { $0.ts > $1.ts }) {
            // Memoir's own window and its own answers are not somewhere the user was.
            guard !MemoryService.isSelfEcho(capture.text),
                  capture.appBundleID != "sh.memoir.app" else { continue }
            let title = capture.windowTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            // A title that is just the app's own name says nothing: "Chrome: Chrome".
            let lowered = title.lowercased()
            guard title.count >= 6, lowered != capture.appName.lowercased() else { continue }
            return Rendered(
                text: "\(Self.oneLine(title))\n\nOn \(capture.appName) at \(fmt.string(from: capture.ts)).",
                captureIDs: [capture.id])
        }
        return Rendered(text: "I do not have anything recent enough to answer that.", captureIDs: [])
    }

    /// The user's own messages, filtered out of parsed chat captures (CF-61).
    ///
    /// Every sender here was read off the screen by `MessageParser` and compared against
    /// the user's configured names; nothing is generated, so nothing can be invented. With
    /// no names configured the honest answer is that Memoir cannot tell: guessing which side
    /// of a chat is "you" is exactly how a memory starts lying about what you said.
    private func renderMyMessages(now: Date) async -> Rendered {
        let own = names()
        guard !own.isEmpty else {
            return Rendered(
                text: "I cannot tell which messages are yours until you add your name in Settings, under Identity.",
                captureIDs: []
            )
        }

        let recent = await safe([CaptureEvent]()) {
            try await store.captures(since: now.addingTimeInterval(-60 * 60 * 24 * 3), limit: 400)
        }

        var lines: [String] = []
        var cited: [ID] = []
        var seen = Set<String>()
        for capture in recent.sorted(by: { $0.ts > $1.ts }) {
            guard MessageParser.isMessagingSurface(
                appBundleID: capture.appBundleID,
                windowTitle: capture.windowTitle
            ) else { continue }
            let mine = MessageParser.messages(in: capture)
                .filter { message in message.sender.map { own.matches(speakerLabel: $0) } ?? false }
            guard !mine.isEmpty else { continue }

            let surface = Self.surfaceName(for: capture)
            var citedThisCapture = false
            for message in mine {
                guard lines.count < 8 else { break }
                // The same window captured twice is the same message twice, not two messages.
                let key = surface.lowercased() + "\u{1}" + message.text.lowercased()
                guard seen.insert(key).inserted else { continue }
                lines.append("- \(surface), \(Self.timeText(capture.ts, now: now)): \(Self.oneLine(message.text))")
                citedThisCapture = true
            }
            if citedThisCapture { cited.append(capture.id) }
            if lines.count >= 8 { break }
        }

        guard !lines.isEmpty else {
            return Rendered(
                text: "I have not seen a message from you on a chat surface in the last 3 days.",
                captureIDs: []
            )
        }
        return Rendered(
            text: (["What you wrote, newest first:"] + lines).joined(separator: "\n"),
            captureIDs: cited
        )
    }

    /// Which conversation surface a capture came from, for naming in an answer.
    ///
    /// "Chrome" is where WhatsApp Web runs, not where the user thinks their messages live,
    /// so the surface is read from the same tokens `MessageParser` routes on. An app this
    /// cannot place keeps its own name, which is at least never wrong.
    static func surfaceName(for capture: CaptureEvent) -> String {
        let haystack = (capture.appBundleID + " " + (capture.windowTitle ?? "")).lowercased()
        for (token, name) in [("whatsapp", "WhatsApp"), ("telegram", "Telegram"),
                              ("slack", "Slack"), ("discord", "Discord"), ("gmail", "Gmail")] {
            if haystack.contains(token) { return name }
        }
        return capture.appName
    }

    private func renderBrief(question: String, now: Date) async -> Rendered {
        let dayStart = Calendar.current.startOfDay(for: now)
        let entities = await safe([Entity]()) { try await store.entities(kind: nil, includeDeleted: false) }
        let sessions = await safe([Session]()) { try await store.sessions(from: dayStart, to: now) }

        guard !entities.isEmpty || !sessions.isEmpty else {
            let stats = await safe(StoreStats(captureCount: 0, entityCount: 0, sessionCount: 0, oldestCapture: nil, fileSizeBytes: 0)) {
                try await store.stats()
            }
            let text = stats.captureCount == 0
                ? "I have not recorded anything yet. Once capture has been running for a while I will be able to answer this."
                : "I have \(stats.captureCount) captures on file but nothing structured out of them yet. Try asking again after the next consolidation."
            return Rendered(text: text, captureIDs: [])
        }

        var lines: [String] = []

        // Anything the question mentions, matched loosely against known entity titles.
        let hits = Self.matches(question: question, in: entities)
        if !hits.isEmpty {
            lines.append("Closest things I have to that:")
            for entity in hits.prefix(5) {
                lines.append("- \(entity.kind.displayName): \(Self.oneLine(entity.title))")
            }
            lines.append("")
        }

        let openCommitments = entities.filter { $0.kind == .commitment && !$0.provisional }
        if !openCommitments.isEmpty {
            let overdue = openCommitments.filter { ($0.dueAt.map { $0 < now }) == true }.count
            let suffix = overdue > 0 ? ", \(overdue) past due" : ""
            lines.append("\(openCommitments.count) open \(openCommitments.count == 1 ? "commitment" : "commitments")\(suffix).")
        }

        let recent = entities.sorted { $0.updatedAt > $1.updatedAt }.prefix(6)
        if !recent.isEmpty {
            lines.append("Recently in play: " + recent.map { Self.oneLine($0.title) }.joined(separator: ", ") + ".")
        }

        let active = sessions.filter { !$0.idle }
        if !active.isEmpty {
            let total = active.reduce(0) { $0 + $1.duration }
            let top = Dictionary(grouping: active, by: \.appName)
                .mapValues { $0.reduce(0) { $0 + $1.duration } }
                .sorted { $0.value > $1.value }
                .first
            if let top {
                lines.append("Today: \(Self.formatDuration(total)) tracked, mostly in \(top.key).")
            }
        }

        lines.append("")
        lines.append("Ask about your commitments, about today, or about a name or project and I will pull what I have.")

        // `hits` is the only part of this brief that responds to what was actually asked.
        // Without it the text is a status report: true, useful when volunteered, and no
        // answer at all when someone asked a question.
        return Rendered(text: lines.joined(separator: "\n"), captureIDs: [], isGeneralBrief: hits.isEmpty)
    }

    // MARK: - Resumption

    /// Work spans for a window, assembled from the store with the ontology applied.
    /// Sessions are clipped to the window and the capture limit is applied to the
    /// window itself: no minute outside [from, to] is ever attributed inside it.
    private func spans(from: Date, to: Date) async -> [WorkSpan] {
        let sessions = WorkSpanBuilder.clip(
            await safe([Session]()) { try await store.sessions(from: from, to: to) },
            from: from, to: to
        )
        let captures = await safe([CaptureEvent]()) {
            try await store.captures(
                from: from.addingTimeInterval(-WorkSpanBuilder.defaultCarryForward), to: to, limit: 4000
            )
        }
        let entities = await safe([Entity]()) { try await store.entities(kind: nil, includeDeleted: false) }
        return WorkSpanBuilder.spans(
            sessions: sessions,
            captures: captures,
            ontology: Ontology.build(from: entities)
        )
    }

    /// "Where did I leave off": the most recent span of work, then the ones before it.
    ///
    /// A timeline of grouped spans, newest described first, each carrying what it was
    /// (project name when the ontology knows, app name when it does not), how long, and
    /// the last thing on screen inside it. Never stale by construction: it widens its
    /// window until it finds the most recent recorded work, and says so when there is none.
    private func renderResumption(question: String, now: Date) async -> Rendered {
        // "What was I doing in 1995" is resumption-shaped and unanswerable: the record
        // starts when Memoir did. Serving today's timeline as the answer implies a record
        // that does not exist, the exact failure `isGeneralBrief` exists to prevent,
        // so the honest decline is marked as one and the router's refusal flow applies.
        if let year = Self.mentionedYear(in: question),
           year != Calendar.current.component(.year, from: now) {
            return Rendered(
                text: "My records only go back as far as Memoir has been running on this Mac. I have nothing from \(year).",
                captureIDs: [],
                isGeneralBrief: true
            )
        }
        let window = MemoryService.resumptionWindow(question, now: now, force: true)
            ?? (since: now.addingTimeInterval(-4 * 3_600), until: nil, label: "the last few hours")
        let windowEnd = window.until ?? now

        var since = window.since
        var label = window.label
        var found = await spans(from: since, to: windowEnd)
        if found.isEmpty, window.until == nil {
            // Nothing in an open-ended window: widen rather than answer stale or empty.
            // A BOUNDED window ("yesterday") never widens: pulling other days' work
            // into yesterday's answer is exactly the wrong-day bug wearing a helpful face.
            for (wider, widerLabel) in [(86_400.0, "the last day"), (7 * 86_400.0, "the last week")] {
                since = now.addingTimeInterval(-wider)
                found = await spans(from: since, to: windowEnd)
                if !found.isEmpty { label = widerLabel; break }
            }
        }
        guard let latest = found.last else {
            if let until = window.until {
                // The asked day is empty; say so, and offer the last real work before it.
                let priorWindow = await spans(from: until.addingTimeInterval(-7 * 86_400), to: until)
                if let prior = priorWindow.last {
                    return Rendered(
                        text: "Nothing tracked \(window.label). The last recorded work before it was **\(prior.label)**, until \(Self.timeText(prior.end, now: now)) (\(prior.apps.joined(separator: ", "))).",
                        captureIDs: Array(prior.captureIDs.suffix(2))
                    )
                }
                return Rendered(text: "Nothing tracked \(window.label).", captureIDs: [])
            }
            return Rendered(
                text: "I have not tracked any work in \(window.label), or in the week before it. Either Memoir was paused or nothing was captured.",
                captureIDs: []
            )
        }

        var lines: [String] = []
        let latestApps = latest.apps.joined(separator: ", ")
        lines.append("You left off on **\(latest.label)** at \(Self.timeText(latest.end, now: now)), \(Self.formatDuration(latest.seconds)) in \(latestApps).")

        // The concrete thing to re-open, when a capture in the span has a title.
        if let captureID = latest.captureIDs.last,
           let capture = await safe(CaptureEvent?.none, { try await store.capture(id: captureID) }),
           let title = capture.windowTitle, !title.isEmpty {
            lines.append("Last on screen: \(Self.oneLine(title)) (\(capture.appName)).")
        }

        let before = found.dropLast().suffix(5).reversed()
        if !before.isEmpty {
            lines.append("")
            lines.append("Before that, in \(label):")
            for span in before {
                let apps = WorkSpanBuilder.appsWorthNaming(span)
                let where_ = apps.isEmpty ? "" : " (\(apps.joined(separator: ", ")))"
                lines.append("- \(span.label): \(Self.formatDuration(span.seconds)), until \(Self.timeText(span.end, now: now))\(where_)")
            }
        }

        var ids = Array(latest.captureIDs.suffix(3))
        for span in before { ids.append(contentsOf: span.captureIDs.suffix(1)) }
        return Rendered(text: lines.joined(separator: "\n"), captureIDs: ids)
    }

    // MARK: - Accounting

    /// The day (or explicitly asked day) an accounting question is about.
    static func accountingWindow(_ q: String, now: Date) -> (start: Date, end: Date, label: String) {
        let calendar = Calendar.current
        let todayStart = calendar.startOfDay(for: now)
        if q.contains("yesterday"),
           let yesterdayStart = calendar.date(byAdding: .day, value: -1, to: todayStart) {
            return (yesterdayStart, todayStart, "yesterday")
        }
        if q.contains("this week"),
           let weekStart = calendar.date(byAdding: .day, value: -7, to: now) {
            return (weekStart, now, "this week")
        }
        return (todayStart, now, "today")
    }

    /// The app a question names, matched against apps actually seen, longest name first.
    ///
    /// Word-boundary matching on a space-normalised haystack: "how long in mail" must
    /// match Mail and must not match inside "mailing" or "gmail": a substring hit on
    /// a fragment is a coincidence, and a confident coincidence attributed to the
    /// wrong app is a wrong number with a straight face.
    /// Words in an app name that identify nothing on their own.
    static let appNameNoise: Set<String> = ["app", "the", "desktop", "beta", "google", "apple", "microsoft"]

    static func matchAppName(_ q: String, candidates: some Sequence<String>) -> String? {
        let haystack = " " + MemoryText.normalizedTitle(q) + " "
        var best: (name: String, score: Int)?
        for name in candidates {
            let normalized = MemoryText.normalizedTitle(name)
            let needle = " " + normalized + " "
            let compact = " " + normalized.replacingOccurrences(of: " ", with: "") + " "
            var score = 0
            if haystack.contains(needle) || (compact.count > 5 && haystack.contains(compact)) {
                score = normalized.count
            } else {
                // Nobody says "Google Chrome"; they say "chrome". A distinctive word of
                // a multi-word app name identifies it, as long as the word carries the
                // identity: "google" and "desktop" do not. Still whole words, so
                // "gmail" cannot match Mail.
                let words = normalized.split(separator: " ").map(String.init)
                    .filter { $0.count >= 4 && !appNameNoise.contains($0) }
                if let hit = words.first(where: { haystack.contains(" \($0) ") }) {
                    score = hit.count
                }
            }
            guard score > 0 else { continue }
            if best == nil || score > best!.score { best = (name, score) }
        }
        return best?.name
    }

    /// Answers the accounting question that was asked, not the one nearest to it.
    private func renderAccounting(ask: AccountingAsk, question: String, now: Date) async -> Rendered {
        let q = question.lowercased()
        let (start, end, label) = Self.accountingWindow(q, now: now)
        // Clipped: an overlap-selected session that started before the window must
        // not bill its pre-window minutes into the asked day's figures.
        let sessions = WorkSpanBuilder.clip(
            await safe([Session]()) { try await store.sessions(from: start, to: end) },
            from: start, to: end
        )
        let active = sessions.filter { !$0.idle && $0.duration > 0 }

        var byApp: [String: TimeInterval] = [:]
        for session in active { byApp[session.appName, default: 0] += session.duration }
        let total = byApp.values.reduce(0, +)

        switch ask {
        case .appTime:
            guard let app = Self.matchAppName(q, candidates: byApp.keys) else {
                // No recognisable app in the question: the total is the honest answer.
                return await renderAccounting(ask: .total, question: question, now: now)
            }
            let appSeconds = byApp[app] ?? 0
            var lines = ["**\(app): \(Self.formatDuration(appSeconds))** \(label)."]
            if total > 0, byApp.count > 1 {
                let share = Int((appSeconds / total * 100).rounded())
                lines.append("That is \(share)% of the \(Self.formatDuration(total)) tracked \(label).")
            }
            if let lastEnd = active.filter({ $0.appName == app }).map(\.endedAt).max() {
                lines.append("Last active there at \(Self.timeText(lastEnd, now: now)).")
            }
            let evidence = await safe([CaptureEvent]()) { try await store.captures(from: start, to: end, limit: 2000) }
                .filter { $0.appName == app }
            return Rendered(text: lines.joined(separator: "\n"), captureIDs: evidence.prefix(3).map(\.id))

        case .total:
            guard !active.isEmpty else {
                return Rendered(text: "No app time tracked \(label) yet.", captureIDs: [])
            }
            let first = active.map(\.startedAt).min() ?? start
            let last = active.map(\.endedAt).max() ?? end
            var lines = ["**\(Self.formatDuration(total))** tracked \(label), from \(Self.timeText(first, now: now)) to \(Self.timeText(last, now: now))."]
            let idle = sessions.filter(\.idle).reduce(0) { $0 + $1.duration }
            if idle > 60 { lines.append("Away from the keyboard for about \(Self.formatDuration(idle)).") }
            if let top = byApp.sorted(by: { $0.value > $1.value }).first {
                lines.append("Most of it in \(top.key) (\(Self.formatDuration(top.value))).")
            }
            return Rendered(text: lines.joined(separator: "\n"), captureIDs: [])

        case .shipped:
            let found = await spans(from: start, to: end)
            let labeled = found.filter { $0.entityID != nil }
            guard !found.isEmpty else {
                return Rendered(text: "Nothing tracked \(label), so I have nothing to report shipped.", captureIDs: [])
            }
            // "Shipped" cannot be verified from a screen; time and evidence can.
            var lines = ["What the record shows for \(label) (where the time went, not a claim about deliverables):"]
            lines.append(contentsOf: Self.spanLines(found, limit: 6))
            let touched = await safe([Entity]()) { try await store.entities(kind: nil, includeDeleted: false) }
                .filter { $0.updatedAt >= start && $0.updatedAt <= end }
            if !touched.isEmpty {
                lines.append("")
                lines.append("Picked up along the way: " + touched.prefix(6).map { Self.oneLine($0.title) }.joined(separator: ", ") + ".")
            }
            var ids: [ID] = []
            for span in labeled.prefix(4) { ids.append(contentsOf: span.captureIDs.suffix(1)) }
            return Rendered(text: lines.joined(separator: "\n"), captureIDs: ids)

        case .summary:
            return await renderToday(now: now, windowStart: start, windowEnd: end, windowLabel: label)

        case .timesheet:
            let (rStart, rEnd) = Self.reportWindow(q, now: now)
            let found = await spans(from: rStart, to: rEnd)
            let sheet = TimesheetBuilder.build(spans: found, from: rStart, to: rEnd)
            var ids: [ID] = []
            for line in sheet.lines.prefix(8) { ids.append(contentsOf: line.captureIDs.suffix(1)) }
            return Rendered(text: TimesheetBuilder.markdown(sheet), captureIDs: ids)

        case .review:
            let (rStart, rEnd) = Self.reportWindow(q, now: now)
            let found = await spans(from: rStart, to: rEnd)
            let sheet = TimesheetBuilder.build(spans: found, from: rStart, to: rEnd)
            let entities = await safe([Entity]()) { try await store.entities(kind: nil, includeDeleted: false) }
            let text = ReviewBuilder.markdown(
                sheet: sheet,
                touched: entities.filter { $0.updatedAt >= rStart && $0.updatedAt <= rEnd },
                commitments: entities.filter { $0.kind == .commitment && !$0.provisional },
                now: now
            )
            var ids: [ID] = []
            for line in sheet.lines.prefix(6) { ids.append(contentsOf: line.captureIDs.suffix(1)) }
            return Rendered(text: text, captureIDs: ids)
        }
    }

    /// The range a timesheet or review covers: an asked day, or the trailing week.
    static func reportWindow(_ q: String, now: Date) -> (start: Date, end: Date) {
        let calendar = Calendar.current
        let todayStart = calendar.startOfDay(for: now)
        if q.contains("yesterday"), let start = calendar.date(byAdding: .day, value: -1, to: todayStart) {
            return (start, todayStart)
        }
        if q.contains("today") { return (todayStart, now) }
        return (calendar.date(byAdding: .day, value: -7, to: now) ?? todayStart, now)
    }

    /// A four-digit year mentioned in the question, if any.
    static func mentionedYear(in question: String) -> Int? {
        var digits = ""
        for ch in question + " " {
            if ch.isNumber {
                digits.append(ch)
            } else {
                if digits.count == 4, let year = Int(digits), (1900...2100).contains(year) {
                    return year
                }
                digits = ""
            }
        }
        return nil
    }

    /// "- **Fenwick Migration**: 2h 05m (Xcode, Chrome)" lines, biggest first.
    static func spanLines(_ spans: [WorkSpan], limit: Int) -> [String] {
        var byLabel: [String: (seconds: TimeInterval, apps: [String], labeled: Bool)] = [:]
        for span in spans {
            var entry = byLabel[span.label] ?? (0, [], span.entityID != nil)
            entry.seconds += span.seconds
            for app in span.apps where !entry.apps.contains(app) { entry.apps.append(app) }
            byLabel[span.label] = entry
        }
        return byLabel.sorted { $0.value.seconds > $1.value.seconds }.prefix(limit).map { label, entry in
            let name = entry.labeled ? "**\(label)**" : label
            return "- \(name): \(formatDuration(entry.seconds)) (\(entry.apps.joined(separator: ", ")))"
        }
    }

    // MARK: - Helpers

    /// Runs a store read, degrading to a fallback instead of propagating storage errors.
    /// This brain is the floor: it must not be the thing that fails.
    private func safe<T>(_ fallback: T, _ body: () async throws -> T) async -> T {
        do {
            return try await body()
        } catch {
            Log.shared.warn("RulesOnlyBrain store read failed: \(error.localizedDescription)")
            return fallback
        }
    }

    /// Loose keyword match of a question against entity titles.
    static func matches(question: String, in entities: [Entity]) -> [Entity] {
        let stop: Set<String> = [
            "what", "when", "who", "why", "how", "the", "a", "an", "is", "are", "was", "were",
            "do", "does", "did", "i", "me", "my", "you", "your", "about", "on", "in", "of",
            "for", "to", "with", "and", "or", "it", "that", "this", "any", "there", "have", "has",
            // Temporal scaffolding. These say when, never what, so matching an entity title
            // on them is always an accident.
            "last", "ago", "recently", "again", "still", "just", "back", "then", "now",
            // "and before that?" matched "…take a look BEFORE the demo?" and offered a
            // commitment as the closest thing it had to a follow-up question about browsing.
            "before", "after", "during", "since", "while",
            // Observational verbs, which say HOW you came across a thing rather than what it
            // was. "looking" was here and "look" was not, which is how "what repo did I LOOK
            // at about screen memory" came back with "Closest things I have to that:
            // Commitment: … Can you TAKE A LOOK before the demo?", a whole-word match on a
            // verb, offered with confidence, about a repo. Found by the fixture eval, which
            // is the kind of thing it is for.
            "looking", "look", "looked", "read", "reading",
            "check", "checking", "checked", "see", "seen", "saw",
        ]
        let words = question.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 2 && !stop.contains($0) }
        guard !words.isEmpty else { return [] }

        // Whole words, not substrings.
        //
        // A bare `title.contains(word)` matched "**last**" in "what was I checking on
        // lmuendeild **last**" against the repo "cadenroe/**last**30days-skill", and offered
        // it as "the closest thing I have to that". A fragment inside a longer token is a
        // coincidence, not a match, and a confident coincidence is the worst thing a memory
        // can produce.
        return entities.filter { entity in
            let titleWords = Set(entity.title.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty })
            return words.contains { titleWords.contains($0) }
        }
        .sorted { $0.confidence > $1.confidence }
    }

    /// The full stop to put after `text`, or `""` when it already ends a sentence.
    ///
    /// Commitment titles are lifted verbatim out of on-screen text, so most of them already
    /// end in a period, a question mark or the ellipsis left by truncation. Appending another
    /// one unconditionally produced lines like "…push an update tomorrow.. due tomorrow.".
    static func sentenceEnd(_ text: String) -> String {
        guard let last = text.last else { return "" }
        return ".!?\u{2026}:;,".contains(last) ? "" : "."
    }

    /// Collapses whitespace so a template line never explodes into a paragraph.
    static func oneLine(_ text: String) -> String {
        text.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// A readable window of text around the first occurrence of `term`.
    static func snippet(from text: String, around term: String, radius: Int = 90) -> String {
        let flat = oneLine(text)
        guard !flat.isEmpty else { return "(no text)" }
        guard let range = flat.range(of: term, options: [.caseInsensitive, .diacriticInsensitive]) else {
            return String(flat.prefix(radius * 2)) + (flat.count > radius * 2 ? "..." : "")
        }
        let lower = flat.index(range.lowerBound, offsetBy: -radius, limitedBy: flat.startIndex) ?? flat.startIndex
        let upper = flat.index(range.upperBound, offsetBy: radius, limitedBy: flat.endIndex) ?? flat.endIndex
        var out = String(flat[lower..<upper])
        if lower > flat.startIndex { out = "..." + out }
        if upper < flat.endIndex { out += "..." }
        return out
    }

    /// "overdue by 3 days", "due today", "due Friday", "no date".
    static func dueDescription(_ due: Date?, now: Date) -> String {
        guard let due else { return "no date" }
        let calendar = Calendar.current
        let days = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: now),
            to: calendar.startOfDay(for: due)
        ).day ?? 0

        switch days {
        case ..<(-1): return "overdue by \(-days) days"
        case -1: return "overdue since yesterday"
        case 0: return "due today"
        case 1: return "due tomorrow"
        case 2...6: return "due \(due.formatted(.dateTime.weekday(.wide)))"
        default: return "due \(due.formatted(date: .abbreviated, time: .omitted))"
        }
    }

    /// "under a minute", "42 min", "3h 10m".
    public static func formatDuration(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded())
        if minutes < 1 { return "under a minute" }
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60
        let rest = minutes % 60
        return rest == 0 ? "\(hours)h" : "\(hours)h \(rest)m"
    }
}
