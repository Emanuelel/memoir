//
//  IdentityTests.swift
//  CF-14: the half of extraction that costs the user their own words.
//
//  ─────────────────────────────────────────────────────────────────────────────
//  The junk guard drops any line carrying a speaker's name, because those are
//  somebody else's words:
//
//      "Marco Bianchi: I'll send the invoice Friday"     correctly ignored
//      "Sofia Marchetti: I'll send the invoice Friday"   ALSO ignored, wrongly
//
//  In Slack, Discord, Teams or any group chat EVERY message is labelled, the
//  user's own included. So the guard that stopped Memoir inventing other people's
//  promises was quietly throwing away the ones the user made themselves, which
//  are the highest-value commitments in the product.
//  ─────────────────────────────────────────────────────────────────────────────
//
//  Memoir cannot know who it belongs to, so it has to be told: `UserNames` is a list
//  because one string cannot describe a person who is a full name in Slack, a
//  handle in Discord and a first name in iMessage.
//
//  Every test here comes in a pair. One says the user's own promise survives; its
//  twin says the same sentence with somebody else's name in front of it does not,
//  and that an empty list behaves exactly as the guard did before any of this
//  existed. A filter that lets everything through is the same bug pointed the
//  other way.
//
//  Nothing in this file calls `UserNames.install`. That value is process-wide, and
//  writing to it here would leak into whatever suite happens to be running in
//  parallel. Names are handed to the extractor and to the predicates explicitly,
//  which is also the only honest way to test them.
//

import Foundation
import Testing

import MemoirFixtures
@testable import MemoirKit

@Suite("CF-14 · the user's own promises are their own")
struct IdentityTests {

    // MARK: - The cast

    /// Whoever this Mac belongs to. Labelled by their full name in Slack, and by a bare
    /// first name or a handle everywhere else, which is exactly why the config is a list.
    private enum Owner {
        static let full = "Sofia Marchetti"
        static let first = "Sofia"
        static let handle = "sofia.marchetti"

        /// Their own promise, in a group chat that labels every line including theirs.
        static let promise = "Sofia Marchetti: I'll send the signed invoice to Acme on Friday."
    }

    /// Everybody else on the same screen.
    private enum Others {
        static let promise = "Marco Bianchi: I'll take the migration this sprint."
        static let tilde = "The Product Circle 7/13/2026 Community Chat ~Pawel : Thanks, Marco! I'll be there."
        static let reported = "Priya said: I'll move the budget into Redis tomorrow"
    }

    /// One Slack screen carrying both promises, in the order they were sent.
    private static func transcript(at ts: Date = TestClock.reference) -> CaptureEvent {
        Fixtures.capture(
            text: """
            \(Owner.promise)
            \(Others.promise)
            """,
            app: "Slack",
            bundleID: "com.tinyspeck.slackmacgap",
            windowTitle: "#finance - Acme",
            at: ts,
            name: "identity-transcript"
        )
    }

    // MARK: - The pipeline, with and without a name

    @Test("CF-14 the user's own promise survives its speaker label")
    func ownPromiseSurvives() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            try await seed(store: store, captures: [Self.transcript()])

            let service = MemoryService(
                store: store,
                extractors: [RuleExtractor(ownNames: UserNames([Owner.full]))]
            )
            _ = try await service.consolidate(since: TestClock.hours(-1), now: TestClock.reference)

            let commitments = try await store.entities(kind: .commitment, includeDeleted: true)
            let titles = commitments.map(\.title)

            #expect(
                titles.contains { $0.localizedCaseInsensitiveContains("signed invoice") },
                "the user's own promise was thrown away with the label in front of it: \(titles)"
            )
            #expect(
                !titles.contains { $0.localizedCaseInsensitiveContains("migration this sprint") },
                "a colleague's promise became the user's: \(titles)"
            )

            // A survivor with no due date is only half a survivor: "Friday" has to resolve
            // for the commitment to be worth anything.
            let invoice = try #require(
                commitments.first { $0.title.localizedCaseInsensitiveContains("signed invoice") }
            )
            #expect(invoice.dueAt != nil, "\"Friday\" did not resolve on the surviving commitment")
            assertNoNetwork()
        }
    }

    @Test("CF-14 with no name configured the same screen still loses both")
    func withoutNamesNothingChanges() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            try await seed(store: store, captures: [Self.transcript()])

            // The default extractor, exactly as the app and memoir-ask build it today.
            let service = MemoryService(store: store, extractors: [RuleExtractor()])
            _ = try await service.consolidate(since: TestClock.hours(-1), now: TestClock.reference)

            let titles = try await store.entities(kind: .commitment, includeDeleted: true).map(\.title)
            #expect(
                titles.isEmpty,
                "a labelled line became a commitment without anyone saying who the user is: \(titles)"
            )
            assertNoNetwork()
        }
    }

    @Test("CF-14 knowing the user's name changes nothing on everyone else's screens")
    func configuredNameLeavesTheFixturesAlone() async throws {
        let anonymous = try await RuleExtractor().extract(from: Fixtures.all())
        let named = try await RuleExtractor(ownNames: UserNames([Owner.full, Owner.first, Owner.handle]))
            .extract(from: Fixtures.all())

        #expect(
            anonymous.entities.map(\.title).sorted() == named.entities.map(\.title).sorted(),
            "configuring a name moved entities on screens the user is not even in"
        )
    }

    // MARK: - The guard itself

    @Test("CF-14 a label matching the user is the user, however it is written")
    func ownLabelsAreRecognised() {
        // Each case is the same sentence twice: once with nobody configured, where it must
        // still be read as somebody else's, and once with the user's names, where it must
        // not. The first half is what proves the second half is not vacuous.
        let cases: [(text: String, names: [String])] = [
            (Owner.promise, [Owner.full]),
            // Case is folded on both sides: a display name arrives however the client renders
            // it, and nobody retypes their own capitalisation to match.
            (Owner.promise, ["sofia marchetti"]),
            (Owner.promise, ["SOFIA MARCHETTI"]),
            // A trailing surname is tolerated in both directions.
            (Owner.promise, [Owner.first]),
            ("Sofia: I'll send the signed invoice to Acme on Friday.", [Owner.full]),
            // The handle from another app reduces to the same words as the display name.
            (Owner.promise, [Owner.handle]),
            // A community chat, where the sender is prefixed with a tilde.
            ("Standup ~Sofia : I'll have the rate limiter fix merged by Friday", [Owner.first]),
            // Reported speech, when a transcript quotes the user back at them.
            ("Sofia said: I'll move the budget into Redis tomorrow", [Owner.first]),
            // One entry among several: the list is what makes this usable at all.
            (Owner.promise, ["marco", Owner.handle, Owner.full]),
        ]

        for (text, names) in cases {
            #expect(
                RuleExtractor.isAttributedToSomeoneElse(text),
                "nothing to fix, this line was never attributed to anyone: \(text)"
            )
            #expect(
                !RuleExtractor.isAttributedToSomeoneElse(text, ownNames: UserNames(names)),
                "the user's own words were read as somebody else's: \(text) with \(names)"
            )
        }
    }

    @Test("CF-14 everybody else is still everybody else")
    func otherPeopleAreUnaffected() {
        let names = UserNames([Owner.full, Owner.handle])
        let others = [
            Others.promise,
            Others.tilde,
            Others.reported,
            "~Pawel: I'll bring the slides",
            "Marco: I'll take the migration this sprint",
            "Elena Rossi: I'll circulate the agenda by Wednesday",
            "Tom wrote: we'll hold the rollout until Friday",
            // Same first name, different person. The full name is what tells them apart.
            "Sofia Bianchi: I'll rewrite the onboarding copy tonight",
        ]
        for text in others {
            #expect(
                RuleExtractor.isAttributedToSomeoneElse(text, ownNames: names),
                "somebody else's promise was handed to the user: \(text)"
            )
        }
    }

    @Test("CF-14 a bare first name claims its namesakes, and that is the cost of it")
    func aBareFirstNameCannotTellNamesakesApart() {
        let namesake = "Sofia Bianchi: I'll rewrite the onboarding copy tonight"

        // "Sofia" cannot separate two Sofias, and refusing to tolerate a trailing surname
        // would throw away the user's own lines in every client that shows one. So a user who
        // enters only a first name is saying that on their screens, Sofia is them. Written
        // down here rather than left to be discovered, because the failure it can cause is an
        // invented commitment.
        #expect(!RuleExtractor.isAttributedToSomeoneElse(namesake, ownNames: UserNames([Owner.first])))

        // The full name is what tells the two apart, which is why the onboarding field opens
        // pre-filled with the account's full name rather than empty.
        #expect(RuleExtractor.isAttributedToSomeoneElse(namesake, ownNames: UserNames([Owner.full])))
        #expect(!RuleExtractor.isAttributedToSomeoneElse(Owner.promise, ownNames: UserNames([Owner.full])))
    }

    @Test("CF-14 the user's own words are still their own")
    func theUsersOwnLinesAreStillKept() {
        // The cases the guard already had to get right, re-run with a name configured: adding
        // an identity may not start rejecting lines that were never labelled at all.
        let names = UserNames([Owner.full, Owner.first])
        let mine = [
            "I'll send the invoice Friday.",
            "I'll follow up with Elena tomorrow about the headcount.",
            "I'll send the Zephyr migration plan to Marco by Friday.",
            "From: Elena Rossi",
            "Subject: Q2 platform review agenda",
            "TODO: chase Elena for the final numbers before the review.",
            "Reminder: I'll send the invoice Friday",
            "Deadline: ship the shared retry budget by Friday",
        ]
        for text in mine {
            #expect(
                !RuleExtractor.isAttributedToSomeoneElse(text, ownNames: names),
                "wrongly rejected: \(text)"
            )
        }
    }

    // MARK: - The empty list is the old behaviour, exactly

    @Test("CF-14 an empty list takes the same path as no list at all")
    func emptyNamesAreTodaysBehaviour() {
        // Every spelling of "the user told us nothing", against a corpus that covers both
        // answers. If any of these four disagree, somebody who never fills the field in has
        // had their memory changed underneath them.
        let corpus: [(text: String, attributed: Bool)] = [
            (Owner.promise, true),
            (Others.promise, true),
            (Others.tilde, true),
            (Others.reported, true),
            ("~Pawel: I'll bring the slides", true),
            ("Elena Rossi: I'll circulate the agenda by Wednesday", true),
            ("I'll send the invoice Friday.", false),
            ("Reminder: I'll send the invoice Friday", false),
            ("Marco asked how we unblock the customer import, I'll look at it tomorrow", false),
            ("ACME-418: I'll close this out by Thursday", false),
        ]
        let empties: [UserNames] = [
            .none,
            UserNames([]),
            // A field the user opened, cleared and left. Blank entries are not names.
            UserNames(["", "   ", "\n"]),
        ]

        for (text, attributed) in corpus {
            #expect(
                RuleExtractor.isAttributedToSomeoneElse(text) == attributed,
                "the guard's own answer moved for: \(text)"
            )
            for empty in empties {
                #expect(empty.isEmpty, "\(empty.entered) should have reduced to no names at all")
                #expect(
                    RuleExtractor.isAttributedToSomeoneElse(text, ownNames: empty) == attributed,
                    "an empty name list changed the answer for: \(text)"
                )
            }
        }
    }

    // MARK: - A name that is also an ordinary word

    @Test("CF-14 a name that is also a common word does not disable the guard")
    func commonWordNamesStayNarrow() {
        // "Sam", "Mark", "Bill", "Will". Real first names, and ordinary English. Matching is
        // by whole word and in order, so they claim the lines that carry them and nothing else.
        for name in ["Sam", "Mark", "Bill"] {
            let names = UserNames([name])
            #expect(
                !RuleExtractor.isAttributedToSomeoneElse("\(name): I'll send the deck tomorrow", ownNames: names),
                "\(name) did not recognise their own line"
            )
            for text in [Others.promise, Others.tilde, Others.reported,
                         "Marco: I'll take the migration this sprint",
                         "Elena Rossi: I'll circulate the agenda by Wednesday"] {
                #expect(
                    RuleExtractor.isAttributedToSomeoneElse(text, ownNames: names),
                    "configuring \"\(name)\" opened the guard for: \(text)"
                )
            }
        }

        // "Mark" is a character prefix of "Marco" and nothing more. Words are compared whole
        // precisely so that a short name never inherits a longer one's promises.
        #expect(RuleExtractor.isAttributedToSomeoneElse("Marco: I'll ship it Friday", ownNames: UserNames(["Marc"])))
        #expect(RuleExtractor.isAttributedToSomeoneElse("Marco: I'll ship it Friday", ownNames: UserNames(["Mar"])))
    }

    @Test("CF-14 a common-word name lets no junk through the pipeline")
    func commonWordNamesKeepTheJunkOut() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            try await seed(store: store, captures: [
                Fixtures.capture(
                    text: """
                    Home

                    mikkel torres @0xquillvox follow i will tell my kids that arden built \
                    this in a cave with a box of scraps 5/30/26, 8:01 PM 28

                    \(Others.tilde)

                    \(Others.promise)
                    """,
                    app: "Google Chrome",
                    bundleID: "com.google.Chrome",
                    windowTitle: "Home",
                    at: TestClock.reference,
                    name: "identity-common-word-junk"
                ),
            ])

            let service = MemoryService(
                store: store,
                extractors: [RuleExtractor(ownNames: UserNames(["Sam", "Bill"]))]
            )
            _ = try await service.consolidate(since: TestClock.hours(-1), now: TestClock.reference)

            let commitments = try await store.entities(kind: .commitment, includeDeleted: true)
            #expect(
                commitments.isEmpty,
                "naming the user let other people's words back in: \(commitments.map(\.title))"
            )
            assertNoNetwork()
        }
    }

    // MARK: - The sweep agrees with the extractor

    @Test("CF-14 the sweep does not retire what the extractor just kept")
    func sweepRespectsTheUsersNames() {
        let mine = makeEntity(kind: .commitment, title: Owner.promise)
        let theirs = makeEntity(kind: .commitment, title: Others.promise)
        let names = UserNames([Owner.full])

        // Without a name, both look like somebody else's words. That is the bug, and it is
        // what a sweep run today would delete.
        #expect(RuleExtractor.isJunkEntity(mine, ownNames: .none))
        #expect(RuleExtractor.isJunkEntity(theirs, ownNames: .none))

        // With one, the sweep and the extractor make the same call. A sweep that disagreed
        // would quietly delete the user's own promises the next time it ran.
        #expect(!RuleExtractor.isJunkEntity(mine, ownNames: names))
        #expect(RuleExtractor.isJunkEntity(theirs, ownNames: names))
    }

    // MARK: - Matching, on its own

    @Test("CF-14 a speaker label matches a name whole, never by prefix")
    func speakerLabelMatching() {
        let names = UserNames([Owner.full])

        // Punctuation and decoration around the label are not part of the name.
        for label in ["Sofia Marchetti", "sofia marchetti", "Sofia", "~Sofia", "Sofia:", "sofia.marchetti"] {
            #expect(names.matches(speakerLabel: label), "did not match: \(label)")
        }

        for label in ["Sofía Marchetti", "SOFIA"] {
            #expect(names.matches(speakerLabel: label), "case or accent folding failed: \(label)")
        }

        for label in ["Sof", "Sofian", "Marchetti", "Marco Bianchi", "Sofia Bianchi", "", "   ", ":"] {
            #expect(!names.matches(speakerLabel: label), "wrongly matched: \(label)")
        }

        // No names configured matches nothing at all, including the empty label.
        for label in ["Sofia Marchetti", "", "Marco"] {
            #expect(!UserNames.none.matches(speakerLabel: label))
        }
    }

    @Test("CF-14 the name list keeps what the user typed and drops what they did not")
    func nameListNormalisation() {
        // Round-trips their own capitalisation, because the config file and the field they
        // typed it into both show it back to them.
        #expect(UserNames([" Sofia Marchetti ", "sofia"]).entered == ["Sofia Marchetti", "sofia"])

        // The same name twice, however it was written, is one name.
        #expect(UserNames(["Sofia", "SOFIA", "sofia "]).entered == ["Sofia"])

        // Nothing usable is not a name.
        #expect(UserNames(["", "  ", ":", "\n"]).isEmpty)
        #expect(UserNames([]).isEmpty)
        #expect(!UserNames(["Sofia"]).isEmpty)
    }
}
