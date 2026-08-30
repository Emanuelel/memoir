//
//  CommitmentRecallTests.swift
//  CF-14d: the other half of precision, measured the same way.
//
//  ─────────────────────────────────────────────────────────────────────────────
//  `CommitmentPrecisionTests` proves the twenty-three junk rows stay out. It was
//  written first and it was written alone, and alone it was not a contract:
//  a memory that refuses everything passes it perfectly.
//
//  It very nearly did. The first cut of those guards, measured over the thirty-five
//  genuine commitments below, kept SEVEN. The branch it replaced kept twenty-eight.
//  It also retired twenty-four already-stored real commitments the first time the
//  sweep ran, where the baseline retired none. Four fifths of the user's promises,
//  deleted silently, in exchange for a junk list that was already going to be swept.
//
//  A minimal-pair test said why: removing only the trigger token from a lost
//  sentence brought fourteen of fifteen straight back. The sentences were never
//  marginal. The guards were keyed to single common words ("nudge", "readme",
//  "localhost", "cookie", "definitely"), and a guard keyed to a common word takes
//  real sentences with it, every time, for as long as it exists.
//
//  So this suite is the floor that keeps the ceiling honest, and the two are meant
//  to be read together:
//
//      CommitmentPrecisionTests   nothing invented   23 of 23 junk rows refused
//      CommitmentRecallTests      nothing lost       at least 26 of 35 kept
//
//  Every sentence below is grouped by the guard that used to eat it, and named with
//  the token that did the eating. If a future guard takes one of these, the failure
//  message says which sentence and which class, which is the whole point: the last
//  regression was invisible until somebody went looking.
//
//  Everything runs through the real `RuleExtractor`. No wall clock, no network.
//

import Foundation
import Testing

import MemoirFixtures
@testable import MemoirKit

@Suite("CF-14d · commitment recall, the floor under the precision guards")
struct CommitmentRecallTests {

    // MARK: - The corpus

    /// One genuine commitment: the sentence, the guard class it stresses, the surface it
    /// belongs on, and the fragment that proves it landed.
    private struct Row: Sendable {
        let id: String
        /// The guard that refused this sentence, and the token it refused it on.
        let cause: String
        let text: String
        let app: String
        let bundleID: String
        let windowTitle: String
        let needle: String

        func capture(index: Int) -> CaptureEvent {
            Fixtures.capture(
                text: text, app: app, bundleID: bundleID, windowTitle: windowTitle,
                at: TestClock.minutes(Double(index)), name: "recall-\(id)"
            )
        }

        /// The same commitment as it would sit in the database after an earlier Memoir
        /// extracted it correctly: an inferred row, holding the promise line.
        func storedCommitment() -> Entity {
            var line = text.split(separator: "\n").map(String.init)
                .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? text
            if text.contains("\n") {
                // Multi-line captures: judge the promise, not the first speaker's line.
                line = text.split(separator: "\n").map(String.init).first {
                    $0.lowercased().contains("i'll") || $0.lowercased().contains("i need")
                } ?? line
            }
            var title = line.trimmingCharacters(in: .whitespaces)
            if title.hasPrefix("- ") { title = String(title.dropFirst(2)) }
            return makeEntity(id: TestID.stable("recall", id), kind: .commitment, title: title,
                              detail: "Commitment in \(app)", confidence: 0.6)
        }
    }

    private static let slack = ("Slack", "com.tinyspeck.slackmacgap", "#eng-platform - Acme")
    private static let notes = ("Notes", "com.apple.Notes", "Admin")
    private static let mail = ("Mail", "com.apple.mail", "Q3 contract")

    private static func R(
        _ id: String, _ cause: String, _ text: String,
        _ surface: (String, String, String), _ needle: String
    ) -> Row {
        Row(id: id, cause: cause, text: text, app: surface.0, bundleID: surface.1,
            windowTitle: surface.2, needle: needle)
    }

    /// Thirty-five commitments that are genuinely the user's.
    ///
    /// Not one is exotic. Every group is named for the guard that refused it and the single
    /// token that did the refusing, so the cost of any future guard is legible.
    private static let corpus: [Row] = [

        // Controls: the five the precision suite already promises.
        R("C1", "control", "I'll send the invoice Friday", slack, "invoice"),
        R("C2", "control", "can you review the PR before standup?", slack, "review the PR"),
        R("C3", "control", "- [ ] renew the domain", notes, "renew the domain"),
        R("C4", "control", "TODO: reply to Marco", notes, "reply to Marco"),
        R("C5", "control", "I need to file the tax return by the 30th", notes, "tax return"),

        // `promisesOnlyASentiment` read the ONE word after "I'll". Six real tasks were
        // wearing an adverb or an auxiliary in that slot.
        R("S1", "sentiment · try", "I'll try to have the design review notes over by Thursday.", slack, "design review notes"),
        R("S2", "sentiment · keep", "I'll keep the staging environment up until the client demo on Friday.", slack, "staging environment"),
        R("S3", "sentiment · definitely", "I'll definitely send the signed contract before Friday.", slack, "signed contract"),
        R("S4", "sentiment · support", "I'll support the launch by writing the release notes on Thursday.", slack, "release notes"),
        R("S5", "sentiment · be", "I'll be at the vendor office Thursday to sign the lease.", slack, "sign the lease"),
        R("S6", "sentiment · remember", "I'll remember to bring the signed W-8 to the meeting tomorrow.", slack, "W-8"),

        // `carriesCodeHostChrome` counted GitHub's vocabulary without asking who was
        // talking. Ordinary developer work reaches three words easily.
        R("G1", "code host · three chrome words", "Can you clone the repo, update the readme and cut a release branch before standup?", slack, "readme"),
        R("G2", "code host · three chrome words", "I'll squash the commits on the release branch and open the pull requests tomorrow.", slack, "squash"),
        R("G3", "code host · path prefix", "src/auth: I'll fix the token refresh before the demo.", notes, "token refresh"),
        R("G4", "code host · breadcrumb", "Reply to the Ask Different thread about the menu bar bug - I'll do it tonight", slack, "Ask Different"),

        // `readsAsPromptToAssistant` matched a bare hostname and a single shouted word.
        R("P1", "prompt · localhost", "I'll fix the localhost redirect bug before the demo tomorrow.", slack, "redirect"),
        R("P2", "prompt · IMPORTANT", "IMPORTANT: I need to send the signed NDA to legal by Monday.", mail, "NDA"),
        R("P3", "prompt · MUST", "Can you sign the lease today? It MUST be filed before Friday.", mail, "lease"),

        // `readsAsProductTour` matched two phrases people say to each other constantly.
        R("T1", "product tour · let's proceed", "Let's proceed with the Friday deploy, I'll prepare the release notes.", slack, "deploy"),
        R("T2", "product tour · you'll be able to", "Can you confirm you'll be able to join the Q3 review on Thursday?", slack, "Q3 review"),

        // `readsAsBroadcastPost` matched sharing a draft and looking at a build.
        R("B1", "broadcast · happy to share", "I'm happy to share the draft with legal, I'll send it Monday.", mail, "draft"),
        R("B2", "broadcast · check out our", "Can you check out our staging build before the demo tomorrow?", slack, "staging build"),

        // `readsAsMemoirsOwnInterface` refused Memoir's vocabulary outright. "nudge" is a verb.
        R("E1", "own vocab · nudge", "I'll nudge Marco about the unpaid invoice tomorrow.", slack, "unpaid invoice"),
        R("E2", "own vocab · due soon", "The domain renewal is due soon, I'll pay it before Friday.", notes, "domain renewal"),
        R("E3", "own vocab · what's due", "Can you tell me what's due tomorrow on the Rossi account?", slack, "Rossi"),

        // `isAllCapsBanner` could not tell caps lock from advertising.
        R("K1", "all caps · a shouted note", "TODO: SEND THE SIGNED LEASE SCAN TO ELENA", notes, "LEASE"),

        // `carriesSiteNameFurniture`, which was already positional and already correct.
        R("N1", "site name · in object position", "I need to cancel Substack before the renewal date.", notes, "Substack"),

        // `readsAsForeignProse` refused the language, not the prose. The user works in
        // Italian, and a task marker is not a claim about English.
        R("F1", "foreign · Italian to-do", "TODO: mandare la fattura che ho promesso a Marco, non oltre venerdi", notes, "fattura"),
        R("F2", "foreign · German to-do", "TODO: die Rechnung bis Freitag an Marco senden und das Angebot nicht vergessen", notes, "Rechnung"),

        // The tightened "due" rule, which lost two shapes of real deadline with the junk.
        R("D1", "due · relative interval", "- Q3 taxes due in two weeks, file them with the accountant", notes, "Q3 taxes"),
        R("D2", "due · at a clock time", "- Signed contract due at 5pm on Friday for the Rossi deal", notes, "Signed contract"),

        // `looksLikePublishedCopy` listed two pieces of real work as site furniture.
        R("W1", "furniture · privacy policy", "I'll draft the privacy policy update before Friday.", slack, "privacy policy"),
        R("W2", "furniture · cookie", "I need to fix the cookie banner before the launch.", slack, "cookie banner"),

        // The blast radius. `readsAsAssistantReply` used to read the WHOLE capture, so one
        // colleague's phrasing deleted every commitment in the thread underneath it.
        R(
            "A1", "assistant register · elsewhere in the thread",
            """
            Marco: want me to take the migration?
            I'll send the invoice Friday.
            Can you review the PR before standup?
            """,
            slack, "invoice"
        ),
        R(
            "A2", "assistant register · elsewhere in the thread",
            """
            Elena: shall I book the room?
            I'll file the tax return by the 30th.
            """,
            slack, "tax return"
        ),
    ]

    /// The contract, as a number. Measured: 7 of 35 on the first cut of the guards, 28 on
    /// the branch before them, 35 today. Twenty-six is the floor a change may not go under
    /// without a deliberate decision and a reason written down.
    private static let floor = 26

    // MARK: - Write time

    @Test("CF-14d the guards keep at least 26 of the 35 genuine commitments")
    func genuineCommitmentsSurviveExtraction() async throws {
        let extractor = RuleExtractor()
        var lost: [String] = []

        for (i, row) in Self.corpus.enumerated() {
            let result = try await extractor.extract(from: [row.capture(index: i)])
            let titles = result.entities.filter { $0.kind == .commitment }.map(\.title)
            if !titles.contains(where: { $0.localizedCaseInsensitiveContains(row.needle) }) {
                lost.append("\(row.id) [\(row.cause)] \"\(row.text)\"")
            }
        }

        let kept = Self.corpus.count - lost.count
        #expect(
            kept >= Self.floor,
            """
            recall \(kept) of \(Self.corpus.count), under the floor of \(Self.floor). \
            A guard is eating real commitments: \(lost.joined(separator: " | "))
            """
        )
        // Today every one of them lands, so name any single loss rather than waiting for
        // nine of them to pile up under the floor.
        #expect(lost.isEmpty, "a genuine commitment was refused: \(lost.joined(separator: " | "))")
    }

    // MARK: - Sweep time

    @Test("CF-14d the sweep retires none of the 35")
    func genuineCommitmentsSurviveTheSweep() {
        // This is the half that hurts. The extractor only ever declines to write a row; the
        // sweep DELETES rows the user is looking at today. The first cut of the guards
        // retired 24 of these 35 the first time it ran.
        var retired: [String] = []
        for row in Self.corpus {
            let stored = row.storedCommitment()
            if RuleExtractor.isJunkEntity(stored) {
                retired.append("\(row.id) [\(row.cause)] \"\(stored.title)\"")
            }
        }
        #expect(
            retired.isEmpty,
            """
            the sweep deleted \(retired.count) of \(Self.corpus.count) genuine commitments \
            already in the user's memory: \(retired.joined(separator: " | "))
            """
        )
    }

    // MARK: - The whole pipeline, on one busy screen

    @Test("CF-14d the extractor and the sweep agree about every one of them")
    func extractorAndSweepAgree() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            try await seed(
                store: store,
                captures: Self.corpus.enumerated().map { $0.element.capture(index: $0.offset) }
            )

            let service = MemoryService(store: store, extractors: [RuleExtractor()])
            _ = try await service.consolidate(since: TestClock.hours(-1), now: TestClock.hours(6))

            let before = try await store.entities(kind: .commitment, includeDeleted: false)
            #expect(before.count >= Self.floor, "only \(before.count) commitments were written")

            let retired = try await service.sweepJunk()
            #expect(
                retired.isEmpty,
                """
                the sweep deleted what the extractor had just accepted, which is the two \
                halves of one predicate disagreeing: \(retired.map(\.title))
                """
            )
            assertNoNetwork()
        }
    }

    // MARK: - Minimal pairs: the token, not the sentence

    @Test("CF-14d no guard turns on a single common token")
    func minimalPairsBehaveTheSameWayBothWays() async throws {
        // Each pair is the same sentence twice: once carrying the token a guard was keyed
        // to, once without it. A guard that reads shape gives the same verdict for both.
        // A guard keyed to the token gives opposite verdicts, and the sentence that happens
        // to contain an ordinary English word is thrown away for containing it.
        let pairs: [(cause: String, withToken: String, without: String)] = [
            ("definitely", "I'll definitely send the signed contract before Friday.",
             "I'll send the signed contract before Friday."),
            ("readme", "Can you clone the repo, update the readme and cut a release branch before standup?",
             "Can you clone the repo, update the docs and cut a release branch before standup?"),
            ("branch", "I'll squash the commits on the release branch and open the pull requests tomorrow.",
             "I'll squash the commits and open the pull requests tomorrow."),
            ("localhost", "I'll fix the localhost redirect bug before the demo tomorrow.",
             "I'll fix the login redirect bug before the demo tomorrow."),
            ("nudge", "I'll nudge Marco about the unpaid invoice tomorrow.",
             "I'll chase Marco about the unpaid invoice tomorrow."),
            ("let's proceed", "Let's proceed with the Friday deploy, I'll prepare the release notes.",
             "Let's go ahead with the Friday deploy, I'll prepare the release notes."),
            ("check out our", "Can you check out our staging build before the demo tomorrow?",
             "Can you look at our staging build before the demo tomorrow?"),
            ("IMPORTANT", "IMPORTANT: I need to send the signed NDA to legal by Monday.",
             "Important: I need to send the signed NDA to legal by Monday."),
            ("want me to", "Marco: want me to take the migration?\nI'll send the invoice Friday.",
             "Marco: can you take the migration?\nI'll send the invoice Friday."),
        ]

        let extractor = RuleExtractor()
        for (n, pair) in pairs.enumerated() {
            func commitments(_ text: String, _ tag: String) async throws -> Int {
                let capture = Fixtures.capture(
                    text: text, app: Self.slack.0, bundleID: Self.slack.1,
                    windowTitle: Self.slack.2, at: TestClock.minutes(Double(n)),
                    name: "recall-pair-\(n)-\(tag)"
                )
                return try await extractor.extract(from: [capture])
                    .entities.filter { $0.kind == .commitment }.count
            }
            let carrying = try await commitments(pair.withToken, "with")
            let without = try await commitments(pair.without, "without")
            #expect(
                carrying > 0 && without > 0,
                """
                "\(pair.cause)" is still load-bearing: the sentence carrying it produced \
                \(carrying) commitments and the same sentence without it produced \(without). \
                A guard is reading the token, not the shape.
                """
            )
        }
    }
}
