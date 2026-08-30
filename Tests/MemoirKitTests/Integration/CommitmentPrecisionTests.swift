//
//  CommitmentPrecisionTests.swift
//  CF-14b: precision, measured on the list the user was actually shown.
//
//  ─────────────────────────────────────────────────────────────────────────────
//  Twenty-four rows were sitting under the heading "Open commitments" in the
//  user's live memory. Twenty-three of them were junk. The one real commitment
//  was the one the user had typed themselves:
//
//      "send the invoice"                          ← PUSH, source == .authored
//  ─────────────────────────────────────────────────────────────────────────────
//
//  A to-do list that is 96% noise is one the user stops opening, and that is the
//  optimistic reading. The pessimistic one is worse: every junk row with a due
//  date is an INVENTED OBLIGATION. Memoir told the user, with a deadline, that they
//  owed something they had never promised. A missed commitment is a disappointment
//  they already know about; an invented one is a claim about their word that they
//  cannot check without going and looking.
//
//  So this suite is written the one direction: when in doubt, refuse. Recall is
//  not the constraint: PUSH exists, and a commitment Memoir declines to guess at is
//  one sentence away from being in the list properly.
//
//  Two halves, and neither is optional:
//
//  1. `Corpus.junk`: those rows verbatim, plus the classes found later on the same
//     list, grouped by the kind of text they came from. None may become a
//     commitment, and every one must be recognised by `RuleExtractor.isJunkEntity`,
//     because the sweep is the only thing that touches the rows the user is
//     looking at *today*.
//  2. `Real.table`: commitments that must still land. If a guard kills one of
//     these, the guard is wrong, not the example.
//
//  Everything runs through the real `RuleExtractor` and the real `MemoryService`
//  against a real SQLite file in a throwaway directory. No wall clock, no network.
//

import Foundation
import Testing

import MemoirFixtures
@testable import MemoirKit

@Suite("CF-14b · commitment precision on the live corpus")
struct CommitmentPrecisionTests {

    // MARK: - The corpus

    /// One junk row: the text verbatim, the class of junk it belongs to, and a plausible
    /// surface for it. The surface matters: half of these are only recognisable as junk
    /// because of where they were read.
    private struct Row: Sendable {
        let family: String
        let text: String
        let app: String
        let bundleID: String
        let windowTitle: String

        /// A capture holding this row and nothing else, so one row can never mask another.
        func capture(index: Int) -> CaptureEvent {
            Fixtures.capture(
                text: text,
                app: app,
                bundleID: bundleID,
                windowTitle: windowTitle,
                at: TestClock.minutes(Double(index)),
                name: "precision-\(family)-\(index)"
            )
        }

        /// This row as it currently sits in the database: an inferred commitment.
        func storedCommitment(index: Int) -> Entity {
            makeEntity(
                id: TestID.stable("precision-junk", String(index)),
                kind: .commitment,
                title: text,
                detail: "Commitment in \(app)",
                confidence: 0.6
            )
        }
    }

    /// The junk rows, verbatim, in the classes they arrived in. Seven were found in the
    /// original twenty-four-row list; the last two came later, from the MCP surface.
    private enum Corpus {

        /// **A · GitHub and repository furniture.** A rendered page has no author and
        /// nothing to do, but it is written in the persuasive register the rules look for.
        static let codeHosting = [
            Row(
                family: "A",
                text: "n1ghtjar/Afterglance: AI-powered screen memory - captures, analyzes, and lets you search/chat your scree",
                app: "Google Chrome", bundleID: "com.google.Chrome",
                windowTitle: "GitHub"
            ),
            Row(
                family: "A",
                text: "main branch 1 Branch 2 Tags Go to file Add file Add file Code Folders and files Folders and files Reposit",
                app: "Google Chrome", bundleID: "com.google.Chrome",
                windowTitle: "GitHub"
            ),
            Row(
                family: "A",
                text: "Afterglance is the only option that's fully MIT open-source, runs on any hardware (including a $150 GPU),",
                app: "Google Chrome", bundleID: "com.google.Chrome",
                windowTitle: "GitHub"
            ),
            Row(
                family: "A",
                text: "macos - The status menu/icon is/are missing in menu bar on M2 MacBook Air due to notch - Ask Different Ap",
                app: "Safari", bundleID: "com.apple.Safari",
                windowTitle: "Ask Different"
            ),
        ]

        /// **B · The user's own prompts, typed at a model.** An instruction to a machine is
        /// discharged the moment it is sent. Nobody is owed anything by it.
        static let promptsToAssistants = [
            Row(
                family: "B",
                text: "ok now let's package all this homepage new addition fo rclaude coce. BE explicit NOT to touch the existin",
                app: "Claude", bundleID: "com.anthropic.claudefordesktop",
                windowTitle: "Claude"
            ),
            Row(
                family: "B",
                text: "can you qccess localhost:4611/ui.html",
                app: "Claude", bundleID: "com.anthropic.claudefordesktop",
                windowTitle: "Claude"
            ),
            Row(
                family: "B",
                text: ", then lets plugins turn it into a focus buddy, reminder system, tiny game, launcher, or coding-agent ...",
                app: "Claude", bundleID: "com.anthropic.claudefordesktop",
                windowTitle: "Claude"
            ),
        ]

        /// **C · Other people's posts.** The promises in these are real. They are simply
        /// somebody else's, addressed to several thousand people who are not the user.
        static let broadcastPosts = [
            Row(
                family: "C",
                text: "I'm incredibly excited to announce that I will be taking on the role of CEO (Director) of Uber Payments E",
                app: "Google Chrome", bundleID: "com.google.Chrome",
                windowTitle: "Feed | LinkedIn"
            ),
            Row(
                family: "C",
                text: "While my role is changing, I know I'll stay closely connected to the legal team.",
                app: "Google Chrome", bundleID: "com.google.Chrome",
                windowTitle: "Feed | LinkedIn"
            ),
            Row(
                family: "C",
                text: "and the entire team. While my role is changing, I know I'll stay closely connected to the legal team.",
                app: "Google Chrome", bundleID: "com.google.Chrome",
                windowTitle: "Feed | LinkedIn"
            ),
            Row(
                family: "C",
                text: "You'll have to catch the LinkedIn Live of the event on 4/9 at 12pm CT (link in the comments), but in the",
                app: "Google Chrome", bundleID: "com.google.Chrome",
                windowTitle: "Feed | LinkedIn"
            ),
            Row(
                family: "C",
                text: "Thanks, Marco! I'll be there.",
                app: "Google Chrome", bundleID: "com.google.Chrome",
                windowTitle: "Feed | LinkedIn"
            ),
        ]

        /// **D · Advertising.** Ad copy is written to sound like a promise. That is its job.
        /// The emoji in the first row is redacted; the rest is verbatim.
        static let marketing = [
            Row(
                family: "D",
                text: "Your MacBook notch is hiding a secret [emoji], This app turns it into one of the most useful features on your M",
                app: "Google Chrome", bundleID: "com.google.Chrome",
                windowTitle: "New tab"
            ),
            Row(
                family: "D",
                text: "SIN PERMANENCIA - TODO INCLUIDO",
                app: "Safari", bundleID: "com.apple.Safari",
                windowTitle: "Tarifas"
            ),
            Row(
                family: "D",
                text: "I will design simple cute 2d cartoon characters Pinterest",
                app: "Safari", bundleID: "com.apple.Safari",
                windowTitle: "Pins"
            ),
        ]

        /// **E · Memoir's own interface copy.** The sharpest lesson in the corpus: Memoir read its
        /// own screen while it was being built and filed its own words as work the user owed.
        static let ownInterface = [
            Row(
                family: "E",
                text: "a nudge, or due soon",
                app: "Xcode", bundleID: "com.apple.dt.Xcode",
                windowTitle: "AskBarController.swift"
            ),
            Row(
                family: "E",
                text: "a nudge, or something due soon",
                app: "Xcode", bundleID: "com.apple.dt.Xcode",
                windowTitle: "AskBarController.swift"
            ),
            Row(
                family: "E",
                text: "\"what's due tomorrow\"",
                app: "Xcode", bundleID: "com.apple.dt.Xcode",
                windowTitle: "AskBarController.swift"
            ),
        ]

        /// **F · An Italian newspaper.** Both of these turn on one word: "due" is a deadline
        /// in English and the number two in Italian.
        static let foreignProse = [
            Row(
                family: "F",
                text: "La distanza tra le due colonne ha un nome: cuneo fiscale e contributivo, la quota di retribuzione che non",
                app: "Safari", bundleID: "com.apple.Safari",
                windowTitle: "Il Sole 24 Ore"
            ),
            Row(
                family: "F",
                text: "Il cuneo ha però due facce: ciò che non arriva in busta finanzia pensioni, sanità, ammortizzatori, cioè s",
                app: "Safari", bundleID: "com.apple.Safari",
                windowTitle: "Il Sole 24 Ore"
            ),
        ]

        /// **G · A third-party product's chatbot.** A product narrating its own flow, in the
        /// first person, the way products do.
        static let productChatter = [
            Row(
                family: "G",
                text: "Let's proceed! You will be able to see the model presented in your TaxDown app.",
                app: "Google Chrome", bundleID: "com.google.Chrome",
                windowTitle: "TaxDown"
            ),
            Row(
                family: "G",
                text: "Tax 6/11/2026 Let's proceed!",
                app: "Google Chrome", bundleID: "com.google.Chrome",
                windowTitle: "TaxDown"
            ),
            Row(
                family: "G",
                text: "If you're comfortable with that (which I'll expand upon in a bit), you'll be able to see the date and any",
                app: "Google Chrome", bundleID: "com.google.Chrome",
                windowTitle: "TaxDown"
            ),
        ]

        /// **H · Documentation prose.** A sentence about what a thing makes possible.
        ///
        /// Found on the live list months after the original twenty-three, by asking the MCP
        /// what was open. The capability verb takes a bare infinitive ("lets Claude *read*"
        /// is shaped exactly like "asks Claude to read"), so a pattern hunting a future-tense
        /// verb finds one. Nobody is in these sentences; that is what makes them copy.
        static let capabilityProse = [
            Row(
                family: "H",
                text: "MCP lets Claude read and write vault notes directly.",
                app: "Google Chrome", bundleID: "com.google.Chrome",
                windowTitle: "Obsidian MCP documentation"
            ),
            Row(
                family: "H",
                text: "By default you paste sources in. MCP lets Claude read and write vault notes",
                app: "Google Chrome", bundleID: "com.google.Chrome",
                windowTitle: "Obsidian MCP documentation"
            ),
            Row(
                family: "H",
                text: "Someone is building an open-source WebXR app that lets you browse your notes in 3D",
                app: "Google Chrome", bundleID: "com.google.Chrome",
                windowTitle: "X"
            ),
        ]

        /// **I · A call to action aimed at a feed.** Two bare imperatives, which is the shape
        /// a to-do has. The difference is the addressee: a readership cannot be owed anything,
        /// and the user cannot discharge it.
        static let audienceCalls = [
            Row(
                family: "I",
                text: "Follow for posts about GitHub repos, DSPy, and agents Subscribe for top posts",
                app: "Google Chrome", bundleID: "com.google.Chrome",
                windowTitle: "X"
            ),
        ]

        /// All twenty-seven, in corpus order.
        static let junk: [Row] =
            codeHosting + promptsToAssistants + broadcastPosts + marketing
            + ownInterface + foreignProse + productChatter
            + capabilityProse + audienceCalls

        /// The one real commitment in the list, and the only one the user recognised.
        ///
        /// It is short, it has no date, and it would never survive extraction, which is
        /// exactly the point. It did not come from extraction. The user said it.
        static let authoredTitle = "send the invoice"

        /// The size of the corpus: every junk row, plus the one real commitment.
        static let size = junk.count + 1
    }

    /// Commitments that are genuinely the user's, in the shapes real commitments arrive in.
    ///
    /// Five ways a sentence qualifies: a first-person promise, a request addressed to the
    /// user, a checkbox in their own notes, an explicit task marker, and a stated obligation.
    /// Each has a junk row in `Corpus` that it is nearly indistinguishable from, which is the
    /// whole difficulty: "I'll send the invoice Friday" and "I'll be there" are the same
    /// sentence to a parser.
    private enum Real {
        static let invoice = "I'll send the invoice Friday"
        static let review = "can you review the PR before standup?"
        static let domain = "- [ ] renew the domain"
        static let marco = "TODO: reply to Marco"
        static let taxes = "I need to file the tax return by the 30th"

        /// The minimal pairs for families H and I: the same trigger words, in sentences that
        /// are somebody's own.
        ///
        /// Every guard in `RuleExtractor` is required to fire on the shape of the junk and
        /// never on a word the junk happens to contain, because the first cut of these guards
        /// kept 7 of 35 real commitments. These three are how families H and I are held to
        /// that. Each carries a capability verb or a subscription call, and each is work:
        /// the first has a speaker, the second leads with its verb, the third has an
        /// addressee. Remove the speaker, the verb or the addressee and they become copy.
        static let licence = "I'll ask Marco if the licence lets us redistribute it"
        static let vendor = "TODO: check whether the vendor allows weekend delivery"
        static let oncall = "can you subscribe to the on-call calendar before Monday?"

        /// Every one of them, and the fragment that proves it landed.
        static let table: [(sentence: String, needle: String)] = [
            (invoice, "invoice"),
            (review, "review the PR"),
            (domain, "renew the domain"),
            (marco, "reply to Marco"),
            (taxes, "tax return"),
            (licence, "redistribute"),
            (vendor, "weekend delivery"),
            (oncall, "on-call calendar"),
        ]

        /// A note and a Slack thread carrying all five, on surfaces where each belongs.
        static func captures() -> [CaptureEvent] {
            [
                Fixtures.capture(
                    text: """
                    #finance

                    \(invoice)
                    \(review)
                    \(licence)
                    \(oncall)
                    """,
                    app: "Slack",
                    bundleID: "com.tinyspeck.slackmacgap",
                    windowTitle: "#finance - Acme",
                    at: TestClock.reference,
                    name: "precision-real-slack"
                ),
                Fixtures.capture(
                    text: """
                    Admin

                    \(domain)
                    \(marco)
                    \(taxes)
                    \(vendor)
                    """,
                    app: "Notes",
                    bundleID: "com.apple.Notes",
                    windowTitle: "Admin",
                    at: TestClock.minutes(90),
                    name: "precision-real-notes"
                ),
            ]
        }
    }

    // MARK: - Nothing in the corpus becomes a commitment

    @Test("CF-14b not one junk row in the corpus becomes a commitment")
    func noJunkRowIsExtracted() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            try await seed(
                store: store,
                captures: Corpus.junk.enumerated().map { $0.element.capture(index: $0.offset) }
            )

            let service = MemoryService(store: store, extractors: [RuleExtractor()])
            _ = try await service.consolidate(since: TestClock.hours(-1), now: TestClock.hours(4))

            let commitments = try await store.entities(kind: .commitment, includeDeleted: true)
            #expect(
                commitments.isEmpty,
                """
                \(commitments.count) of \(Corpus.junk.count) junk rows became an obligation the user never made: \
                \(commitments.map(\.title))
                """
            )
            // A due date on a junk row is the failure mode that hurts: it puts the invention
            // in front of the user at a specific hour, as if it were a real deadline.
            #expect(
                commitments.allSatisfy { $0.dueAt == nil },
                "a junk row was given a deadline: \(commitments.filter { $0.dueAt != nil }.map(\.title))"
            )
            assertNoNetwork()
        }
    }

    @Test("CF-14b every junk row is recognised by a guard, one by one")
    func everyJunkRowIsRecognised() {
        for (i, row) in Corpus.junk.enumerated() {
            let entity = row.storedCommitment(index: i)
            #expect(
                RuleExtractor.isJunkEntity(entity),
                "class \(row.family) row \(i) is invisible to the sweep: \"\(row.text)\""
            )
        }
    }

    // MARK: - The sweep, which is the only thing the user can see today

    @Test("CF-14c the sweep retires every junk row and leaves the one the user typed")
    func sweepClearsTheCorpus() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            let service = MemoryService(store: store, extractors: [RuleExtractor()])

            try await seed(
                store: store,
                entities: Corpus.junk.enumerated().map { $0.element.storedCommitment(index: $0.offset) }
            )
            // The real one goes in the way it really went in: through PUSH, in the user's
            // own words. `sweepJunk` must never judge those, whatever they say.
            let intent = try #require(
                PushParser.parseRouted(Corpus.authoredTitle, reference: TestClock.reference),
                "the push path stopped accepting the sentence this whole suite is anchored on"
            )
            _ = try await service.commitPush(intent, now: TestClock.reference)

            let before = try await store.entities(kind: .commitment, includeDeleted: false)
            #expect(before.count == Corpus.size, "the corpus did not go in whole: \(before.count) rows")

            let retired = try await service.sweepJunk()
            #expect(
                retired.count == Corpus.junk.count,
                "the sweep left junk behind: retired \(retired.count) of \(Corpus.junk.count)"
            )

            let after = try await store.entities(kind: .commitment, includeDeleted: false)
            #expect(after.count == 1, "what survived was not just the real one: \(after.map(\.title))")
            let survivor = try #require(after.first)
            #expect(survivor.source == .authored)
            #expect(
                survivor.title.localizedCaseInsensitiveContains("invoice"),
                "the sweep deleted the user's own commitment and kept junk: \(survivor.title)"
            )

            // CF-14c: a second sweep finds nothing. A sweep that keeps finding work is a
            // sweep that is not actually deleting, or one that disagrees with itself.
            let second = try await service.sweepJunk()
            #expect(second.isEmpty, "the sweep is not idempotent: \(second.map(\.title))")
        }
    }

    @Test("CF-14b precision on the live corpus: every surviving row is a real commitment")
    func precisionOnTheLiveCorpus() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            let service = MemoryService(store: store, extractors: [RuleExtractor()])

            try await seed(
                store: store,
                entities: Corpus.junk.enumerated().map { $0.element.storedCommitment(index: $0.offset) }
            )
            let intent = try #require(PushParser.parseRouted(Corpus.authoredTitle, reference: TestClock.reference))
            _ = try await service.commitPush(intent, now: TestClock.reference)

            _ = try await service.sweepJunk()

            let surviving = try await store.entities(kind: .commitment, includeDeleted: false)
            let real = surviving.filter { $0.source == .authored }
            let precision = surviving.isEmpty ? 0 : Double(real.count) / Double(surviving.count)

            // The list started at one real row in twenty-four, which is 4%. Anything short of
            // "every row left is real" puts an invented obligation back in front of the user.
            #expect(
                precision == 1.0,
                """
                precision \(Int(precision * 100))%: \(real.count) real of \(surviving.count) shown. \
                Junk still in the list: \(surviving.filter { $0.source != .authored }.map(\.title))
                """
            )
            #expect(surviving.count == 1, "the corpus should leave exactly one row standing")
        }
    }

    // MARK: - The real commitments, which must not be casualties

    @Test("CF-14b every real commitment in the table still lands")
    func realCommitmentsSurviveExtraction() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            try await seed(store: store, captures: Real.captures())

            let service = MemoryService(store: store, extractors: [RuleExtractor()])
            _ = try await service.consolidate(since: TestClock.hours(-1), now: TestClock.hours(4))

            let titles = try await store.entities(kind: .commitment, includeDeleted: true).map(\.title)
            for entry in Real.table {
                #expect(
                    titles.contains { $0.localizedCaseInsensitiveContains(entry.needle) },
                    "a real commitment was refused: \"\(entry.sentence)\" missing from \(titles)"
                )
            }

            // "Friday" has to resolve, or the row lands in the list with no date and the user
            // has to remember the one thing they asked Memoir to remember for them.
            let invoice = try #require(
                try await store.entities(kind: .commitment, includeDeleted: true)
                    .first { $0.title.localizedCaseInsensitiveContains("invoice") }
            )
            #expect(invoice.dueAt != nil, "\"Friday\" did not resolve on the surviving commitment")
        }
    }

    @Test("CF-14b the sweep does not retire the real commitments either")
    func realCommitmentsSurviveTheSweep() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            let service = MemoryService(store: store, extractors: [RuleExtractor()])
            try await seed(store: store, captures: Real.captures())
            _ = try await service.consolidate(since: TestClock.hours(-1), now: TestClock.hours(4))

            let before = try await store.entities(kind: .commitment, includeDeleted: false).map(\.title)
            let retired = try await service.sweepJunk()
            #expect(
                retired.isEmpty,
                "the sweep deleted commitments the extractor had just accepted: \(retired.map(\.title))"
            )

            let after = try await store.entities(kind: .commitment, includeDeleted: false).map(\.title)
            #expect(after.count == before.count)
        }
    }

    @Test("CF-14b a colleague's request keeps its speaker label through the sweep")
    func labelledRequestsSurviveTheSweep() {
        // The extractor stores this on purpose: a speaker label disqualifies a promise, not
        // a question, and a question in a transcript on the user's screen is addressed to
        // them. A sweep that read the label differently would delete live work.
        let request = makeEntity(
            kind: .commitment,
            title: "Marco: can you drop the migration notes in here before the review?"
        )
        #expect(!RuleExtractor.isJunkEntity(request))

        let promise = makeEntity(
            kind: .commitment,
            title: "Priya: I'll move the budget into Redis and push an update tomorrow."
        )
        #expect(RuleExtractor.isJunkEntity(promise), "somebody else's promise survived the sweep")
    }

    // MARK: - The guards, one class at a time

    @Test("CF-14b class A · a repository page is not a task list")
    func codeHostChromeIsRecognised() {
        for row in Corpus.codeHosting where row.text.contains("Afterglance:") || row.text.contains("Branch") {
            #expect(RuleExtractor.carriesCodeHostChrome(row.text), "not caught: \(row.text)")
        }
        #expect(RuleExtractor.carriesCodeHostChrome(
            "macos - The status menu/icon is missing in menu bar - Ask Different Ap"
        ))
        #expect(RuleExtractor.carriesCodeHostChrome("expo/expo-router: file-based routing for React Native"))

        for kept in [
            Real.invoice,
            Real.review,
            // The same words, in the middle of a real promise. Position is the whole signal.
            "I'll push the fix to GitHub tomorrow",
            "Can you review the pull requests before the release cut?",
            // Two pieces of vocabulary, and a completely ordinary request. Three are needed.
            "Can you clone the repo and update the readme before standup?",
            // A path label in front of the writer's own to-do, which is a repository
            // heading to the character until you read what comes after the colon.
            "src/auth: fix the token refresh before the demo",
            "- Finishing the migration script, will hand it over by Thursday.",
        ] {
            #expect(!RuleExtractor.carriesCodeHostChrome(kept), "wrongly rejected: \(kept)")
        }
    }

    @Test("CF-14b class B · a prompt is an instruction to a machine")
    func promptsToAssistantsAreRecognised() {
        for row in Corpus.promptsToAssistants {
            #expect(RuleExtractor.readsAsPromptToAssistant(row.text), "not caught: \(row.text)")
        }
        #expect(RuleExtractor.readsAsPromptToAssistant("DO NOT change the existing homepage"))
        #expect(RuleExtractor.readsAsPromptToAssistant("can you check localhost:3000 for me"))

        for kept in [
            Real.invoice, Real.review, Real.marco, Real.taxes,
            // An acronym is not a shout.
            "Can you review the PR and the RFC before standup?",
            "TODO: chase Elena for the final numbers before the review.",
            "ACME-418: I'll close this out by Thursday",
        ] {
            #expect(!RuleExtractor.readsAsPromptToAssistant(kept), "wrongly rejected: \(kept)")
        }
    }

    @Test("CF-14b class B · an assistant surface yields no commitments at all")
    func assistantSurfacesAreRefusedOutright() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            try await seed(store: store, captures: [
                Fixtures.capture(
                    text: """
                    can you review the PR before standup?
                    I'll send the invoice Friday
                    TODO: reply to Marco
                    """,
                    app: "Claude",
                    bundleID: "com.anthropic.claudefordesktop",
                    windowTitle: "Claude",
                    at: TestClock.reference,
                    name: "precision-assistant-surface"
                ),
            ])

            let service = MemoryService(store: store, extractors: [RuleExtractor()])
            _ = try await service.consolidate(since: TestClock.hours(-1), now: TestClock.hours(2))

            // Every line here would be a commitment anywhere else, which is the point: a
            // date or a TODO marker used to be enough to get a prompt through. It is not.
            let commitments = try await store.entities(kind: .commitment, includeDeleted: true)
            #expect(
                commitments.isEmpty,
                "a prompt typed at a model became a promise: \(commitments.map(\.title))"
            )
        }
    }

    @Test("CF-14b class C · an announcement to a feed is not a promise to the user")
    func broadcastPostsAreRecognised() {
        #expect(RuleExtractor.readsAsBroadcastPost(Corpus.broadcastPosts[0].text))
        #expect(RuleExtractor.readsAsBroadcastPost(Corpus.broadcastPosts[3].text))
        #expect(RuleExtractor.readsAsBroadcastPost("Thrilled to announce I'll be joining Acme next month"))

        for kept in [Real.invoice, Real.review, "I'll share the deck with the team by Wednesday"] {
            #expect(!RuleExtractor.readsAsBroadcastPost(kept), "wrongly rejected: \(kept)")
        }
    }

    @Test("CF-14b class C · a promise with nothing to finish is a feeling")
    func sentimentPromisesAreRecognised() {
        for text in [
            Corpus.broadcastPosts[1].text,
            Corpus.broadcastPosts[2].text,
            Corpus.broadcastPosts[4].text,
            "I'll always be grateful for this team",
            "we'll keep in touch",
        ] {
            #expect(RuleExtractor.promisesOnlyASentiment(text), "not caught: \(text)")
        }

        for kept in [
            Real.invoice,
            "I'll have the fix merged and deployed by Friday so QA gets a clean build.",
            "I will write up the migration notes tomorrow and post them in this channel.",
            "I'll circulate the updated agenda by Wednesday",
            "I'll move the budget into Redis and push an update tomorrow.",
            // An auxiliary in front of real work is still real work.
            "I'll be sending the invoice on Friday",
        ] {
            #expect(!RuleExtractor.promisesOnlyASentiment(kept), "wrongly rejected: \(kept)")
        }
    }

    @Test("CF-14b class D · advertising is not an obligation")
    func marketingIsRecognised() {
        #expect(RuleExtractor.readsAsMarketingPitch(Corpus.marketing[0].text))
        #expect(RuleExtractor.readsAsMarketingPitch(Corpus.codeHosting[2].text))
        #expect(RuleExtractor.isAllCapsBanner(Corpus.marketing[1].text))
        #expect(RuleExtractor.carriesSiteNameFurniture(Corpus.marketing[2].text))

        for kept in [Real.invoice, Real.marco, Real.taxes, "I'll post the update on LinkedIn tonight"] {
            #expect(!RuleExtractor.readsAsMarketingPitch(kept), "pitch wrongly rejected: \(kept)")
            #expect(!RuleExtractor.isAllCapsBanner(kept), "banner wrongly rejected: \(kept)")
            #expect(!RuleExtractor.carriesSiteNameFurniture(kept), "site name wrongly rejected: \(kept)")
        }
    }

    @Test("CF-14b class E · Memoir's own vocabulary can never be a commitment")
    func ownInterfaceCopyIsRecognised() {
        for row in Corpus.ownInterface {
            #expect(RuleExtractor.readsAsMemoirsOwnInterface(row.text), "not caught: \(row.text)")
        }
        #expect(RuleExtractor.readsAsMemoirsOwnInterface("Ask Memoir about your work"))

        for kept in Real.table.map(\.sentence) {
            #expect(!RuleExtractor.readsAsMemoirsOwnInterface(kept), "wrongly rejected: \(kept)")
        }
    }

    @Test("CF-14b class F · prose these rules cannot read is refused, not guessed at")
    func foreignProseIsRecognised() {
        for row in Corpus.foreignProse {
            #expect(RuleExtractor.readsAsForeignProse(row.text), "not caught: \(row.text)")
        }

        for kept in [
            Real.invoice, Real.review, Real.taxes,
            "I'll have the fix merged and deployed by Friday so QA gets a clean build.",
            "Action item for you: confirm the final headcount numbers before the review.",
        ] {
            #expect(!RuleExtractor.readsAsForeignProse(kept), "wrongly rejected: \(kept)")
        }
    }

    @Test("CF-14b class G · a product describing itself is not making a promise")
    func productChatterIsRecognised() {
        for row in Corpus.productChatter {
            #expect(RuleExtractor.readsAsProductTour(row.text), "not caught: \(row.text)")
        }

        for kept in [
            Real.invoice, Real.review,
            "I'll walk you through the migration on Thursday",
            "we'll take care of the Finance rollup before the review",
        ] {
            #expect(!RuleExtractor.readsAsProductTour(kept), "wrongly rejected: \(kept)")
        }
    }

    // MARK: - "due" is a deadline, not a preposition

    @Test("CF-14b \"due\" only counts when a date follows it")
    func dueNeedsADate() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            try await seed(store: store, captures: [
                Fixtures.capture(
                    text: """
                    Reading

                    the status icon is missing due to the notch on this model
                    the report is due tomorrow and I still have not started it
                    """,
                    app: "Safari",
                    bundleID: "com.apple.Safari",
                    windowTitle: "Reading",
                    at: TestClock.reference,
                    name: "precision-due-preposition"
                ),
            ])

            let service = MemoryService(store: store, extractors: [RuleExtractor()])
            _ = try await service.consolidate(since: TestClock.hours(-1), now: TestClock.hours(2))

            let titles = try await store.entities(kind: .commitment, includeDeleted: true).map(\.title)
            #expect(
                !titles.contains { $0.localizedCaseInsensitiveContains("due to the notch") },
                "a preposition became a deadline: \(titles)"
            )
            #expect(
                titles.contains { $0.localizedCaseInsensitiveContains("report is due tomorrow") },
                "a real deadline was lost with it: \(titles)"
            )
        }
    }

    // MARK: - The rest of the memory is unharmed

    @Test("CF-14b the precision guards cost the fixtures nothing")
    func fixturesKeepTheirCommitments() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            try await seed(store: store, captures: Fixtures.all())

            let service = MemoryService(store: store, extractors: [RuleExtractor()])
            _ = try await service.consolidate(since: TestClock.days(-1), now: TestClock.hours(1))

            let titles = try await store.entities(kind: .commitment, includeDeleted: false).map(\.title)
            for wanted in ["deployed by Friday", "Can you also drop the migration notes",
                           "Action item for you", "hand it over by Thursday",
                           "chase Elena", "rollback runbook"] {
                #expect(
                    titles.contains { $0.localizedCaseInsensitiveContains(wanted) },
                    "\"\(wanted)\" was lost to the precision guards: \(titles)"
                )
            }

            // And the sweep agrees with the extractor about every one of them.
            let retired = try await service.sweepJunk()
            #expect(retired.isEmpty, "the sweep and the extractor disagree: \(retired.map(\.title))")
            assertNoNetwork()
        }
    }
}
