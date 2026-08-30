//
//  ChatAnswerTests.swift
//  CF-61 / CF-62: "what did I write" is answerable, and your own labelled promise survives.
//
//  ─────────────────────────────────────────────────────────────────────────────
//  CF-61: "what did I write on whatsapp" fell through to the general brief and
//  was answered with "10 open commitments. Recently in play: ...". A status
//  report, and an answer to no question. The fix is the same shape as the
//  .mostRecent superlative: recognise the phrasing exactly, then FILTER parsed
//  messages by the user's configured names. No model anywhere: every sender in
//  the answer was read off the screen by MessageParser, never guessed.
//
//  CF-62: chat apps label EVERY message, the user's own included. Exempting the
//  label from the attribution guard (CF-14) kept the line; stripping it is what
//  makes "Chiara Ferri: I'll send the invoice Friday" land as the first-person
//  promise the user actually typed, date and all, while Marco's identical
//  sentence still lands nowhere.
//  ─────────────────────────────────────────────────────────────────────────────
//
//  Names are injected everywhere: into the brain through its test initialiser and
//  into the extractor through its public one. Nothing here calls `UserNames.install`:
//  that value is process-global and a write would leak into whatever suite happens to
//  be running alongside. The one router test runs with no names on purpose, because
//  the honest no-names sentence is the only CF-61 answer that does not depend on a
//  clock the router builds for itself.
//

import Foundation
import Testing

import MemoirFixtures
@testable import MemoirKit

@Suite("CF-61 · what did I write is answerable")
struct ChatAnswerTests {

    // MARK: - The cast

    /// Whoever this Mac belongs to, anonymised. A full name in Slack, a bare first name
    /// in WhatsApp group previews, which is exactly why the config is a list.
    private static let owner = UserNames(["Chiara Ferri"])

    // MARK: - Fixtures

    /// A WhatsApp Web chat-list capture. The shape is the real one (compact row, then the
    /// same content re-broken across lines); the content is invented: header
    /// furniture, two of the user's own group messages, two other people's rows.
    private static let whatsAppText = """
        (2) WhatsApp
        Updates in Status
        WhatsApp
        Search or start a new chat
        All
        Unread
        Favorites
        Groups
        Chat list
        Padel Thursday Chiara :  I'll send the invoice Friday, promise
        Padel
        Thursday
        Chiara
        :
        I'll send the invoice Friday, promise
        La Piazza 6:49 PM Bruno :  Sta a piove da du ore
        La Piazza
        6:49 PM
        Bruno
        :
        Sta a piove da du ore
        Cineclub Wednesday Chiara Ferri :  booked the padel court for tuesday
        Cineclub
        Wednesday
        Chiara Ferri
        :
        booked the padel court for tuesday
        Marco Bruni Friday tuttobene allora ci vediamo li
        Marco Bruni
        Friday
        tuttobene allora ci vediamo li
        """

    private static func whatsApp(at ts: Date) -> CaptureEvent {
        Fixtures.capture(
            text: whatsAppText,
            app: "Google Chrome",
            bundleID: "com.google.Chrome",
            windowTitle: "(2) WhatsApp - Google Chrome",
            at: ts,
            name: "chat-answer-whatsapp"
        )
    }

    /// A Slack capture, newer than the WhatsApp one, so "newest first" is observable.
    private static func slack(at ts: Date) -> CaptureEvent {
        Fixtures.capture(
            text: """
            #fatturazione
            Chiara Ferri 10:45 AM
            I'll push the new logo tonight
            Marco Bruni 10:47 AM
            perfetto
            """,
            app: "Slack",
            bundleID: "com.tinyspeck.slackmacgap",
            windowTitle: "#fatturazione - Acme",
            at: ts,
            name: "chat-answer-slack"
        )
    }

    /// The same user's words on a surface that is not a chat. Must never enter the answer.
    private static func notes(at ts: Date) -> CaptureEvent {
        Fixtures.capture(
            text: "Chiara Ferri: remember the padel racket",
            app: "Notes",
            bundleID: "com.apple.Notes",
            windowTitle: "Shopping list",
            at: ts,
            name: "chat-answer-notes"
        )
    }

    /// A WhatsApp capture older than the three-day window. Must never enter the answer.
    private static func staleWhatsApp(at ts: Date) -> CaptureEvent {
        Fixtures.capture(
            text: """
            Chat list
            Padel Monday Chiara :  OLD do not show this one
            Padel
            Monday
            Chiara
            :
            OLD do not show this one
            """,
            app: "Google Chrome",
            bundleID: "com.google.Chrome",
            windowTitle: "(1) WhatsApp - Google Chrome",
            at: ts,
            name: "chat-answer-whatsapp-stale"
        )
    }

    private static func brain(_ store: Store, names: UserNames) -> RulesOnlyBrain {
        RulesOnlyBrain(store: store, now: { TestClock.reference }, names: { names })
    }

    // MARK: - Routing

    @Test("CF-61 the messages phrasings all route to the messages shape")
    func phrasingsRoute() {
        let questions = [
            "what did I write on whatsapp",
            "what did I send to Marco",
            "what did I say on slack",
            "what was my last message",
            "my last messages",
            "messages I sent yesterday",
            "what have I written on telegram",
        ]
        for q in questions {
            #expect(RulesOnlyBrain.asksForMyMessages(q), "did not route: \(q)")
        }
        #expect(RulesOnlyBrain.classify("what did I write on whatsapp") == .myMessages)
    }

    @Test("CF-61 note-taking, documents and commitment questions never route to messages")
    func nonMessagesPhrasingsDoNot() {
        let questions = [
            // An instruction to Memoir, not a question about the past.
            "write down a note to call Marco",
            "write a summary of today",
            // A different surface entirely: the doc is not a chat.
            "what did I write in the doc",
            "what did I write in my notes",
            // A commitments question wearing message words.
            "what did I say I would do",
            // The neighbouring superlative keeps its own route.
            "what was the last site",
        ]
        for q in questions {
            #expect(!RulesOnlyBrain.asksForMyMessages(q), "wrongly routed: \(q)")
        }
        #expect(RulesOnlyBrain.classify("what was the last site") == .mostRecent)
        #expect(RulesOnlyBrain.classify("write down a note to call Marco") != .myMessages)
    }

    // MARK: - With names configured

    @Test("CF-61 with names configured the answer is the user's messages and nobody else's")
    func namesConfiguredReturnsOnlyTheUsersMessages() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            let whatsApp = Self.whatsApp(at: TestClock.hours(-2))
            try await seed(store: store, captures: [
                Self.staleWhatsApp(at: TestClock.days(-5)),
                whatsApp,
                Self.slack(at: TestClock.hours(-1)),
                Self.notes(at: TestClock.minutes(-30)),
            ])

            let answer = try await Self.brain(store, names: Self.owner)
                .answer(question: "what did I write on whatsapp", context: .empty)

            // The user's messages, from both parsed surfaces, each naming its surface.
            #expect(answer.text.contains("I'll send the invoice Friday, promise"))
            #expect(answer.text.contains("booked the padel court for tuesday"))
            #expect(answer.text.contains("I'll push the new logo tonight"))
            #expect(answer.text.contains("WhatsApp"))
            #expect(answer.text.contains("Slack"))

            // Nobody else's words, nothing stale, nothing from a non-chat surface.
            #expect(!answer.text.contains("Sta a canta"))
            #expect(!answer.text.contains("tuttobene"))
            #expect(!answer.text.contains("OLD do not show"))
            #expect(!answer.text.contains("padel racket"))

            // A messages answer, not the general brief.
            #expect(!answer.text.contains("open commitment"))
            #expect(!answer.text.contains("Recently in play"))

            // Newest first: the Slack capture is an hour fresher than the WhatsApp one.
            let slackAt = try #require(answer.text.range(of: "I'll push the new logo tonight"))
            let whatsAppAt = try #require(answer.text.range(of: "I'll send the invoice Friday, promise"))
            #expect(slackAt.lowerBound < whatsAppAt.lowerBound, "messages were not newest first")

            #expect(answer.brain == .rulesOnly)
            #expect(answer.citedCaptureIDs.contains(whatsApp.id))
            assertNoNetwork()
        }
    }

    // MARK: - With no names configured

    @Test("CF-61 with no names the answer is the honest sentence, never a guess")
    func noNamesIsAnHonestGap() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            try await seed(store: store, captures: [Self.whatsApp(at: TestClock.hours(-2))])

            let answer = try await Self.brain(store, names: .none)
                .answer(question: "what did I write on whatsapp", context: .empty)

            #expect(answer.text.contains(
                "I cannot tell which messages are yours until you add your name in Settings, under Identity."
            ))
            // Not a guess: no message text, no sender, no brief.
            #expect(!answer.text.contains("invoice"))
            #expect(!answer.text.contains("Chiara"))
            #expect(!answer.text.contains("Recently in play"))
            assertNoNetwork()
        }
    }

    // MARK: - End to end, through the router

    @Test("CF-61 end to end the router lands on the messages shape, never the brief")
    func endToEndThroughTheRouter() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            try await seed(store: store, captures: [Self.whatsApp(at: TestClock.hours(-2))])

            // The router builds its own RulesOnlyBrain, which reads `UserNames.current`.
            // Nothing in this suite installs names, so the deterministic end-to-end answer
            // is the honest no-names sentence, which is itself half of CF-61's contract,
            // and proof the question was routed to the messages shape rather than falling
            // through to the general brief.
            let router = BrainRouter(preferred: .rulesOnly, store: store, config: TestBrainConfig.localOnly)
            let answer = try await router.answer(question: "what did I write on whatsapp", context: .empty)

            #expect(answer.brain == .rulesOnly)
            #expect(answer.text.contains(
                "I cannot tell which messages are yours until you add your name in Settings, under Identity."
            ))
            #expect(!answer.text.contains("open commitment"))
            #expect(!answer.text.contains("Recently in play"))
            assertNoNetwork()
        }
    }
}

// MARK: - CF-62

@Suite("CF-62 · your own labelled promise survives, in a chat")
struct OwnLabelledPromiseTests {

    private static let owner = UserNames(["Chiara Ferri"])

    /// One Slack screen, both promises, word for word the same except for who is speaking.
    private static func transcript(at ts: Date = TestClock.reference) -> CaptureEvent {
        Fixtures.capture(
            text: """
            Chiara Ferri: I'll send the invoice Friday
            Marco Bianchi: I'll send the deck Friday
            """,
            app: "Slack",
            bundleID: "com.tinyspeck.slackmacgap",
            windowTitle: "#finance - Acme",
            at: ts,
            name: "cf62-transcript"
        )
    }

    @Test("CF-62 the user's labelled promise lands stripped, with its date; Marco's does not land")
    func bothDirections() async throws {
        let result = try await RuleExtractor(ownNames: Self.owner)
            .extract(from: [Self.transcript()])
        let commitments = result.entities.filter { $0.kind == .commitment }
        let titles = commitments.map(\.title)

        // The user's own promise, and only theirs.
        #expect(
            titles.contains { $0.localizedCaseInsensitiveContains("send the invoice") },
            "the user's own labelled promise was eaten: \(titles)"
        )
        #expect(
            !titles.contains { $0.localizedCaseInsensitiveContains("send the deck") },
            "a colleague's promise became the user's: \(titles)"
        )

        let mine = try #require(
            commitments.first { $0.title.localizedCaseInsensitiveContains("send the invoice") }
        )

        // Stripped, not merely exempted: the stored title is the sentence the user typed,
        // not the chat client's rendering of it.
        #expect(
            !mine.title.localizedCaseInsensitiveContains("Chiara"),
            "the speaker label rode into the stored title: \(mine.title)"
        )

        // And the date resolved: a promise without its Friday is only half a promise.
        let due = try #require(mine.dueAt, "\"Friday\" did not resolve on the surviving commitment")
        #expect(
            TestClock.localCalendar.component(.weekday, from: due) == 6,
            "\"Friday\" resolved to \(TestClock.iso(due)), which is not a Friday"
        )
    }

    @Test("CF-62 without names the same screen still loses both, exactly as before")
    func withoutNamesNothingMoves() async throws {
        let result = try await RuleExtractor(ownNames: .none)
            .extract(from: [Self.transcript()])
        let titles = result.entities.filter { $0.kind == .commitment }.map(\.title)
        #expect(
            titles.isEmpty,
            "a labelled line became a commitment without anyone saying who the user is: \(titles)"
        )
    }

    @Test("CF-62 the stripper and the attribution guard agree about what a label is")
    func stripperAgreesWithTheGuard() {
        // Strips: the user's own head label, one word or two.
        #expect(
            RuleExtractor.strippingOwnSpeakerLabel(
                from: "Chiara Ferri: I'll send the invoice Friday", ownNames: Self.owner
            ) == "I'll send the invoice Friday"
        )
        #expect(
            RuleExtractor.strippingOwnSpeakerLabel(
                from: "Chiara: I'll send the invoice Friday", ownNames: Self.owner
            ) == "I'll send the invoice Friday"
        )

        // Refuses: everyone else, line labels, and no names at all.
        for (segment, names) in [
            ("Marco Bianchi: I'll send the deck Friday", Self.owner),
            ("Reminder: I'll send the invoice Friday", Self.owner),
            ("I'll send the invoice Friday", Self.owner),
            ("Chiara Ferri: I'll send the invoice Friday", UserNames.none),
        ] {
            #expect(
                RuleExtractor.strippingOwnSpeakerLabel(from: segment, ownNames: names) == nil,
                "wrongly stripped: \(segment)"
            )
        }
    }
}
