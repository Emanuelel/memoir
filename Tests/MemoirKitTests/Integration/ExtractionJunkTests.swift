//
//  ExtractionJunkTests.swift
//  CF-14: the precision half of extraction.
//
//  ─────────────────────────────────────────────────────────────────────────────
//  Three rows lifted verbatim out of the user's live memory, where they were shown
//  under the heading "Open commitments":
//
//    "mikkel torres @0xquillvox follow i will tell my kids that arden built this
//     in a cave with a box of scraps 5/30/26, 8:01 PM 28"
//    "The Product Circle 7/13/2026 Community Chat ~Pawel : Thanks, Marco! I'll be there."
//    "gentler/hand-drawn"                                     ← filed as a PROJECT
//  ─────────────────────────────────────────────────────────────────────────────
//
//  The first two are strangers' words scraped off a timeline and a group chat, and
//  Memoir told the user they owed them. That is the worst thing this product can do:
//  a missed commitment is a gap the user already knows about, an invented one is a
//  claim about what they promised. The third is two adjectives from a note about how
//  an icon should look, presented as a piece of work in progress.
//
//  CF-14 says extraction finds commitments. These say what it must refuse to find,
//  and every test that rejects junk is paired with one that keeps a real commitment
//  in the same shape: an over-eager filter is the same bug pointed the other way.
//
//  Everything runs through the real `RuleExtractor` and the real `MemoryService`
//  against a real SQLite file in a throwaway directory.
//

import Foundation
import Testing

import MemoirFixtures
@testable import MemoirKit

@Suite("CF-14b · extraction refuses other people's words")
struct ExtractionJunkTests {

    // MARK: - The live junk, verbatim

    /// The three rows exactly as the memory browser rendered them.
    private enum Junk {

        /// A stranger's post on X, complete with handle, Follow button, post footer and
        /// reply count, all flattened into one captured line.
        static let timelinePost = """
        mikkel torres @0xquillvox follow i will tell my kids that arden built this in a \
        cave with a box of scraps 5/30/26, 8:01 PM 28
        """

        /// A community chat, where the sender's display name is prefixed with a tilde.
        static let groupChatReply =
            "The Product Circle 7/13/2026 Community Chat ~Pawel : Thanks, Marco! I'll be there."

        /// A design note. The slash is a designer weighing two looks.
        static let styleNote = "Icon direction: single-stroke outline face, gentler/hand-drawn"
    }

    /// Commitments that are genuinely the user's, in the same surfaces the junk came from.
    private enum Real {

        /// The headline survivor: an ordinary promise in Slack, with a bare weekday.
        static let invoice = "I'll send the invoice Friday."

        /// A request addressed to the user, with a handle in it: the handle alone must
        /// never be enough to reject something.
        static let handledRequest = "@marco can you review the pricing deck before the launch?"

        /// A promise that happens to contain "follow", which is also a timeline button.
        static let followUp = "I'll follow up with Elena tomorrow about the headcount."

        /// A standup bullet with the subject dropped, which is how notes are written.
        static let bullet = "- Finishing the migration script, will hand it over by Thursday."

        /// A bare imperative to-do. CF-54 is built on this sentence, and the first cut of
        /// the personal-voice guard threw it away.
        static let toDo = "Send the signed lease scan to Elena by Friday"
    }

    // MARK: - The whole pipeline, junk and real in one screen

    @Test("CF-14b the three live junk rows produce no commitment and no project")
    func liveJunkIsNotStored() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            try await seed(store: store, captures: [
                Fixtures.capture(
                    text: """
                    Home

                    \(Junk.timelinePost)

                    \(Junk.groupChatReply)

                    \(Junk.styleNote)
                    """,
                    app: "Google Chrome",
                    bundleID: "com.google.Chrome",
                    windowTitle: "Home",
                    at: TestClock.reference,
                    name: "junk-live-rows"
                ),
            ])

            let service = MemoryService(store: store, extractors: [RuleExtractor()])
            _ = try await service.consolidate(since: TestClock.hours(-1), now: TestClock.reference)

            let commitments = try await store.entities(kind: .commitment, includeDeleted: true)
            #expect(
                commitments.isEmpty,
                "a stranger's post became something the user owes: \(commitments.map(\.title))"
            )

            let projects = try await store.entities(kind: .project, includeDeleted: true)
            #expect(
                !projects.contains { $0.title.lowercased().contains("hand-drawn") },
                "a style token became a project: \(projects.map(\.title))"
            )
        }
    }

    @Test("CF-14b a real commitment on the same screen as the junk still lands")
    func realCommitmentSurvivesAlongsideJunk() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            try await seed(store: store, captures: [
                Fixtures.capture(
                    text: """
                    \(Junk.timelinePost)

                    \(Junk.groupChatReply)

                    \(Real.invoice)
                    \(Real.handledRequest)
                    \(Real.followUp)
                    \(Real.bullet)
                    """,
                    app: "Slack",
                    bundleID: "com.tinyspeck.slackmacgap",
                    windowTitle: "#finance - Acme",
                    at: TestClock.reference,
                    name: "junk-and-real"
                ),
            ])

            let service = MemoryService(store: store, extractors: [RuleExtractor()])
            _ = try await service.consolidate(since: TestClock.hours(-1), now: TestClock.reference)

            let commitments = try await store.entities(kind: .commitment, includeDeleted: true)
            let titles = commitments.map(\.title)

            for wanted in ["invoice", "pricing deck", "follow up with Elena", "hand it over by Thursday"] {
                #expect(
                    titles.contains { $0.localizedCaseInsensitiveContains(wanted) },
                    "a genuine commitment was filtered away: \"\(wanted)\" missing from \(titles)"
                )
            }
            for unwanted in ["arden", "be there"] {
                #expect(
                    !titles.contains { $0.localizedCaseInsensitiveContains(unwanted) },
                    "junk survived: \"\(unwanted)\" present in \(titles)"
                )
            }

            // "I'll send the invoice Friday" is the one that must never be lost, so its
            // date is checked too: a survivor with no due date is only half a survivor.
            let invoice = try #require(
                commitments.first { $0.title.localizedCaseInsensitiveContains("invoice") }
            )
            #expect(invoice.dueAt != nil, "\"Friday\" did not resolve on the surviving commitment")
        }
    }

    // MARK: - Social timeline furniture

    @Test("CF-14b a post's own chrome marks it as somebody else's")
    func timelineFurnitureIsRecognised() {
        #expect(RuleExtractor.carriesTimelineFurniture(Junk.timelinePost))

        let posts = [
            // The footer, on its own. Date, clock and meridiem together.
            "i will get to it 5/30/26, 8:01 PM",
            // Handle plus a timeline verb.
            "@0xquillvox follow i will tell my kids about this",
            "@someone 1.2K likes and I'll do it anyway",
            "@dhh 340 reposts, we're shipping it regardless",
            // Chrome no message ever contains.
            "Show this thread. I'll explain the rest below",
            "View more replies, and I'll answer each one",
        ]
        for post in posts {
            #expect(RuleExtractor.carriesTimelineFurniture(post), "not caught: \(post)")
        }
    }

    @Test("CF-14b ordinary work is not mistaken for a timeline")
    func realWorkCarriesNoTimelineFurniture() {
        let real = [
            Real.invoice,
            // A handle alone is a colleague, not a post author.
            Real.handledRequest,
            "@priya I'll have the migration notes for you by Wednesday",
            // "follow up" is the single most common shape a real commitment takes.
            Real.followUp,
            "@elena can you follow up with Finance before the review?",
            // A date without the post-footer shape around it.
            "The deadline is 30/05/2026 and I'll have it done before then",
            "Standup moved to 8:01, I'll be there",
            Real.bullet,
        ]
        for text in real {
            #expect(!RuleExtractor.carriesTimelineFurniture(text), "wrongly rejected: \(text)")
        }
    }

    // MARK: - Named third parties

    @Test("CF-14b a promise with someone else's name in front of it is theirs")
    func speakerLabelsAreRecognised() {
        #expect(RuleExtractor.isAttributedToSomeoneElse(Junk.groupChatReply))

        let others = [
            "~Pawel : Thanks, Marco! I'll be there.",
            "~Pawel: I'll bring the slides",
            "Marco: I'll take the migration this sprint",
            "Elena Rossi: I'll circulate the agenda by Wednesday",
            "Priya said: I'll move the budget into Redis tomorrow",
            "Tom wrote: we'll hold the rollout until Friday",
        ]
        for text in others {
            #expect(RuleExtractor.isAttributedToSomeoneElse(text), "not caught: \(text)")
        }
    }

    @Test("CF-14b naming someone inside your own promise does not give it away")
    func namesInsideTheUsersOwnWordsAreKept() {
        let mine = [
            Real.invoice,
            Real.followUp,
            // CF-40's sentence. A name as the *object* is not a speaker label.
            "I'll send the Zephyr migration plan to Marco by Friday.",
            "Marco asked how we unblock the customer import, I'll look at it tomorrow",
            // Mail headers are the same shape and are not people talking.
            "From: Elena Rossi",
            "Subject: Q2 platform review agenda",
            // An all-caps marker is not a first name.
            "TODO: chase Elena for the final numbers before the review.",
            "ACME-418: I'll close this out by Thursday",
            // A label on your own line is the same shape as a speaker on someone else's.
            "Reminder: I'll send the invoice Friday",
            "Deadline: ship the shared retry budget by Friday",
            "Blocker: can you unblock the Finance rollup?",
        ]
        for text in mine {
            #expect(!RuleExtractor.isAttributedToSomeoneElse(text), "wrongly rejected: \(text)")
        }
    }

    @Test("CF-14b a colleague's question to the user survives its speaker label")
    func speakerLabelledRequestsStillLand() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            try await seed(store: store, captures: [
                Fixtures.capture(
                    text: """
                    Marco: can you drop the migration notes in here before the review?
                    Priya: I'll move the budget into Redis and push an update tomorrow.
                    """,
                    app: "Slack",
                    bundleID: "com.tinyspeck.slackmacgap",
                    windowTitle: "#eng-platform - Acme",
                    at: TestClock.reference,
                    name: "junk-labelled-transcript"
                ),
            ])

            let service = MemoryService(store: store, extractors: [RuleExtractor()])
            _ = try await service.consolidate(since: TestClock.hours(-1), now: TestClock.reference)

            let titles = try await store.entities(kind: .commitment, includeDeleted: true).map(\.title)
            #expect(
                titles.contains { $0.localizedCaseInsensitiveContains("migration notes") },
                "a request addressed to the user was thrown away with its speaker: \(titles)"
            )
            #expect(
                !titles.contains { $0.localizedCaseInsensitiveContains("Redis") },
                "Priya's own promise was stored as the user's: \(titles)"
            )
        }
    }

    // MARK: - First person, or addressed to the user

    @Test("CF-14b a commitment has to involve the user at all")
    func personalVoiceIsRequired() {
        for text in [Real.invoice, Real.handledRequest, Real.followUp,
                     "we're going to cut the release on Friday",
                     "Can you confirm the headcount before the review?"] {
            #expect(RuleExtractor.readsAsFirstPersonOrAddressed(text), "wrongly rejected: \(text)")
        }

        for text in ["Registration due by Friday for the Barcelona marathon",
                     "Payment due on receipt, terms net 30",
                     "the release train departs by Thursday every fortnight"] {
            #expect(!RuleExtractor.readsAsFirstPersonOrAddressed(text), "not caught: \(text)")
        }
    }

    @Test("CF-14b documentation describes what a thing can do, and promises nothing")
    func capabilityProseIsNotAPromise() {
        for text in ["MCP lets Claude read and write vault notes directly.",
                     "By default you paste sources in. MCP lets Claude read and write vault notes",
                     "Someone is building an open-source WebXR app that lets you browse your notes in 3D",
                     "The new tier enables SSO for every workspace",
                     "Memoir allows any agent to read the record"] {
            #expect(RuleExtractor.describesACapability(text), "not caught: \(text)")
        }

        // The minimal pairs. Same verb, but somebody is in the sentence (a speaker, an
        // addressee, or the missing subject of a to-do) and each of these is real work.
        for text in ["I'll ask Marco if the licence lets us redistribute it",
                     "can you confirm the vendor allows weekend delivery?",
                     "TODO: check whether the vendor allows weekend delivery",
                     "Check whether the licence allows redistribution",
                     "we'll see if the plan lets us export to CSV"] {
            #expect(!RuleExtractor.describesACapability(text), "wrongly refused: \(text)")
        }
    }

    @Test("CF-14b a call to a feed is not a task the user can finish")
    func audienceCallsAreNotTasks() {
        for text in ["Follow for posts about GitHub repos, DSPy, and agents Subscribe for top posts",
                     "Like and subscribe for more",
                     "Link in bio"] {
            #expect(RuleExtractor.solicitsAnAudience(text), "not caught: \(text)")
        }

        for text in ["I'll subscribe to the on-call calendar tonight",
                     "can you subscribe to the on-call calendar before Monday?",
                     "TODO: subscribe to the status page"] {
            #expect(!RuleExtractor.solicitsAnAudience(text), "wrongly refused: \(text)")
        }
    }

    @Test("CF-97 a name the timeline promoted is not somebody the user knows")
    func feedNamesAreNotPeople() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()

            // X's trending sidebar, which is where "Jorge Martín" came from on the real
            // database: a person at 99% confidence with twelve mentions, every one of them
            // an algorithm choosing what to show. On a feed, repetition is the product.
            let feed = (1...6).map { index in
                Fixtures.capture(
                    text: "Trending in Spain Jorge Messi Trending with Jorge Martín More \(index)",
                    app: "Google Chrome", bundleID: "com.google.Chrome",
                    windowTitle: "Home / X - Google Chrome",
                    at: TestClock.minutes(Double(index)), name: "feed-\(index)"
                )
            }
            // The same name, in a message the user is actually in. A direct message is not
            // a feed: CF-91's invoice promise was typed into exactly such a thread.
            let thread = Fixtures.capture(
                text: "From: Elena Rossi\nsending the migration notes over now",
                app: "Google Chrome", bundleID: "com.google.Chrome",
                windowTitle: "Messaging | LinkedIn",
                at: TestClock.minutes(20), name: "dm"
            )
            try await seed(store: store, captures: feed + [thread])

            let service = MemoryService(store: store, extractors: [RuleExtractor()])
            _ = try await service.consolidate(since: TestClock.hours(-1), now: TestClock.hours(4))

            let people = try await store.entities(kind: .person, includeDeleted: true).map(\.title)
            #expect(!people.contains { $0.contains("Jorge") },
                    "a trending name became somebody the user knows: \(people)")
            #expect(people.contains { $0.contains("Elena") },
                    "a name from a real conversation was lost: \(people)")
        }
    }

    @Test("CF-97 the sweep retires people only ever seen on a feed")
    func feedOnlyPeopleAreSwept() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()

            func person(_ title: String, id: String) throws -> Entity {
                let e = makeEntity(id: TestID.stable("feed", id), kind: .person, title: title, confidence: 0.9)
                return e
            }

            // Written before the guard existed, which is the only reason the sweep exists.
            let promoted = try person("Jorge Martín", id: "promoted")
            let colleague = try person("Elena Rossi", id: "colleague")
            try await store.upsert(entity: promoted)
            try await store.upsert(entity: colleague)

            let feedCapture = Fixtures.capture(
                text: "Trending with Jorge Martín", app: "Google Chrome",
                bundleID: "com.google.Chrome", windowTitle: "Home / X - Google Chrome",
                at: TestClock.minutes(-30), name: "sweep-feed"
            )
            let mailCapture = Fixtures.capture(
                text: "From: Elena Rossi, the migration notes", app: "Mail",
                bundleID: "com.apple.mail", windowTitle: "Inbox", at: TestClock.minutes(-20),
                name: "sweep-mail"
            )
            try await store.insert(capture: feedCapture)
            try await store.insert(capture: mailCapture)
            try await store.add(provenance: makeProvenance(
                entityID: promoted.id, captureID: feedCapture.id,
                snippet: "Trending with Jorge Martín", at: TestClock.minutes(-30)
            ))
            try await store.add(provenance: makeProvenance(
                entityID: colleague.id, captureID: mailCapture.id,
                snippet: "From: Elena Rossi", at: TestClock.minutes(-20)
            ))

            let service = MemoryService(store: store, extractors: [RuleExtractor()])
            let retired = try await service.retireFeedOnlyPeople()

            #expect(retired.map(\.title) == ["Jorge Martín"], "retired: \(retired.map(\.title))")
            let left = try await store.entities(kind: .person, includeDeleted: false).map(\.title)
            #expect(left.contains("Elena Rossi"), "a real contact was swept: \(left)")
        }
    }

    @Test("CF-96 an application's own name is never a person")
    func applicationNamesAreNotPeople() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()

            // Every window title on a Mac ends in the app's name, so it is the one phrase
            // guaranteed to repeat beside everything the user has ever looked at. The
            // repetition path read that as a name recurring and filed "Google Chrome" as a
            // person at 55% confidence, where it reached the daily brief.
            let lines = (1...6).map { index in
                Fixtures.capture(
                    text: "Notes from Google Chrome and Google Chrome, with Google Chrome again \(index)",
                    app: "Google Chrome", bundleID: "com.google.Chrome",
                    windowTitle: "Something - Google Chrome",
                    at: TestClock.minutes(Double(index)), name: "chrome-\(index)"
                )
            }
            try await seed(store: store, captures: lines)

            let service = MemoryService(store: store, extractors: [RuleExtractor()])
            _ = try await service.consolidate(since: TestClock.hours(-1), now: TestClock.hours(4))

            let people = try await store.entities(kind: .person, includeDeleted: true).map(\.title)
            #expect(
                !people.contains { $0.localizedCaseInsensitiveContains("Google Chrome") },
                "the application filed itself as a person: \(people)"
            )
        }
    }

    @Test("CF-96 a social timeline's furniture is not a person either")
    func timelineFurnitureIsNotAPerson() {
        // Read off X, where these words sit beside every post and so repeat exactly the way
        // a frequently-mentioned colleague's name would.
        for name in ["Quote Machina Verified", "Clearer Responses Trending", "Clearer Responses"] {
            #expect(!RulePatterns.isPlausiblePersonName(name), "filed as a person: \(name)")
        }
        // And the guard is keyed to the furniture, not to capitalisation: real names that
        // merely sit near it survive.
        for name in ["Machina Rossi", "Jorge Martín", "Elena"] {
            #expect(RulePatterns.isPlausiblePersonName(name), "wrongly refused: \(name)")
        }
    }

    @Test("CF-89 an organisation is not a person")
    func organisationsAreNotPeople() {
        // "Vercel Inc" was a person at 75% confidence, and `who_is` answered about it as
        // though it were a colleague. It arrived as a bot's display name in a mail header,
        // otherwise the most reliable person signal on the screen.
        for name in ["Vercel Inc", "Acme Ltd", "Stripe Inc.", "Basecamp LLC",
                     "Contoso GmbH", "Initech Holdings", "Hooli Labs", "dependabot bot",
                     // Spelled out, which "inc" alone did not cover: found on the real
                     // database as "Lovable Labs Incorporated", filed as a person.
                     "Lovable Labs Incorporated"] {
            #expect(!RulePatterns.isPlausiblePersonName(name), "filed as a person: \(name)")
        }

        // Only the trailing word counts, and only when there is a name in front of it. A
        // person really can be called Ivy Labs; "Labs" alone is not a company either.
        for name in ["Marco", "Elena Rossi", "Ivy", "Labs", "Inc",
                     "Jean-Luc Picard", "Priya R"] {
            #expect(RulePatterns.isPlausiblePersonName(name), "wrongly refused: \(name)")
        }

        // The sweep has to know it too. Adding a guard to the extractor and not to
        // `isJunkEntity` is the mistake this file has made three times: "Vercel Inc" was
        // already stored at 99% confidence with 24 mentions, and stopping new ones did
        // nothing for the one `who_is` was still answering about.
        #expect(RuleExtractor.isJunkEntity(makeEntity(kind: .person, title: "Vercel Inc")))
        #expect(!RuleExtractor.isJunkEntity(makeEntity(kind: .person, title: "Elena Rossi")))
    }

    @Test("CF-14b a bullet is the writer's own, subject or no subject")
    func bulletsCountAsTheWritersOwn() {
        #expect(RuleExtractor.startsWithBullet(Real.bullet))
        #expect(RuleExtractor.startsWithBullet("  * Ship the runbook before the demo"))
        #expect(RuleExtractor.startsWithBullet("\u{2022} Hand over the migration script by Thursday"))

        #expect(!RuleExtractor.startsWithBullet("-5 degrees overnight"))
        #expect(!RuleExtractor.startsWithBullet("--force is the wrong flag here"))
        #expect(!RuleExtractor.startsWithBullet(Real.invoice))
    }

    @Test("CF-14b a bare imperative is a to-do, not a headline")
    func toDosKeepTheirMissingSubject() {
        #expect(RuleExtractor.startsWithTaskVerb(Real.toDo))
        for text in ["Chase Elena for the final numbers before the review",
                     "Review the pricing deck by Thursday",
                     "Renew the domain before it lapses on Friday"] {
            #expect(RuleExtractor.startsWithTaskVerb(text), "wrongly rejected: \(text)")
        }

        // A page that opens with an imperative is selling, not reminding.
        for text in ["Registration due by Friday for the Barcelona marathon",
                     "Subscribe by Friday and get 20% off",
                     "Download the app before the deadline"] {
            #expect(!RuleExtractor.startsWithTaskVerb(text), "not caught: \(text)")
        }
    }

    @Test("CF-14b a to-do written as a bare imperative still becomes a commitment")
    func bareImperativeToDoIsStored() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            try await seed(store: store, captures: [
                Fixtures.capture(
                    text: """
                    Flat move

                    \(Real.toDo)
                    Deposit is with the previous agency
                    """,
                    app: "Notes",
                    bundleID: "com.apple.Notes",
                    windowTitle: "Flat move",
                    at: TestClock.reference,
                    name: "junk-bare-imperative"
                ),
            ])

            let service = MemoryService(store: store, extractors: [RuleExtractor()])
            _ = try await service.consolidate(since: TestClock.hours(-1), now: TestClock.reference)

            let titles = try await store.entities(kind: .commitment, includeDeleted: true).map(\.title)
            #expect(
                titles.contains { $0.localizedCaseInsensitiveContains("signed lease scan") },
                "the user's own to-do was filtered away as somebody else's: \(titles)"
            )
        }
    }

    @Test("CF-14b a page's deadline is not the user's commitment")
    func impersonalDeadlinesAreNotStored() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            try await seed(store: store, captures: [
                Fixtures.capture(
                    text: """
                    Race information

                    Registration due by Friday for the Barcelona marathon
                    Bib collection closes by Sunday at the expo
                    """,
                    app: "Safari",
                    bundleID: "com.apple.Safari",
                    windowTitle: "Race information",
                    at: TestClock.reference,
                    name: "junk-impersonal-deadline"
                ),
            ])

            let service = MemoryService(store: store, extractors: [RuleExtractor()])
            _ = try await service.consolidate(since: TestClock.hours(-1), now: TestClock.reference)

            let commitments = try await store.entities(kind: .commitment, includeDeleted: true)
            #expect(
                commitments.isEmpty,
                "a web page's deadline became the user's: \(commitments.map(\.title))"
            )
        }
    }

    // MARK: - Style tokens are not projects

    @Test("CF-14b design vocabulary is not a project")
    func styleTokensAreRecognised() {
        #expect(RuleExtractor.looksLikeStyleToken("gentler/hand-drawn"))

        let tokens = [
            "gentler/hand-drawn",
            "hand-drawn/sketchy",
            "muted/desaturated",
            "rounded/squared",
            "border-radius/8px",
            "sans-serif/monospace",
            "flex-start/space-between",
        ]
        for token in tokens {
            #expect(RuleExtractor.looksLikeStyleToken(token), "not caught: \(token)")
        }
    }

    @Test("CF-14b a real repository slug is still a project")
    func realSlugsSurvive() {
        for slug in ["acme-corp/platform", "priya-r/rate-limiter", "expo/expo-router", "vercel/next.js"] {
            #expect(!RuleExtractor.looksLikeStyleToken(slug), "wrongly rejected: \(slug)")
        }

        #expect(RulePatterns.isPlausibleSlug(owner: "acme-corp", repo: "platform"))
        #expect(!RulePatterns.isPlausibleSlug(owner: "gentler", repo: "hand-drawn"))
    }

    @Test("CF-14b the design note yields no project, the code review still does")
    func slugsAreSeparatedInThePipeline() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            try await seed(store: store, captures: [
                Fixtures.capture(
                    text: Junk.styleNote,
                    app: "Notes",
                    bundleID: "com.apple.Notes",
                    windowTitle: "Icon exploration",
                    at: TestClock.reference,
                    name: "junk-style-note"
                ),
                Fixtures.codeReview(at: TestClock.minutes(6)),
            ])

            let service = MemoryService(store: store, extractors: [RuleExtractor()])
            _ = try await service.consolidate(since: TestClock.hours(-1), now: TestClock.hours(1))

            let titles = try await store.entities(kind: .project, includeDeleted: true).map(\.title)
            #expect(
                !titles.contains { $0.localizedCaseInsensitiveContains("hand-drawn") },
                "the style note became a project: \(titles)"
            )
            #expect(
                titles.contains { $0.localizedCaseInsensitiveContains("acme-corp/platform") },
                "the real repository was lost with it: \(titles)"
            )
        }
    }

    // MARK: - The fixtures are unchanged

    @Test("CF-14b the guards cost the fixtures nothing")
    func realisticScreensStillYieldTheirCommitments() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            try await seed(store: store, captures: Fixtures.all())

            let service = MemoryService(store: store, extractors: [RuleExtractor()])
            _ = try await service.consolidate(since: TestClock.days(-1), now: TestClock.hours(1))

            let titles = try await store.entities(kind: .commitment, includeDeleted: false).map(\.title)
            #expect(titles.count >= 10, "the junk guards took real commitments with them: \(titles)")

            // One from each fixture, spanning every way a commitment qualifies: first
            // person, addressed to the user, an explicit action item, and a bare bullet.
            for wanted in ["deployed by Friday", "Can you also drop the migration notes",
                           "Action item for you", "hand it over by Thursday"] {
                #expect(
                    titles.contains { $0.localizedCaseInsensitiveContains(wanted) },
                    "\"\(wanted)\" was lost: \(titles)"
                )
            }
            assertNoNetwork()
        }
    }
}
