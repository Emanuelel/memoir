import Foundation
import Testing
import MemoirFixtures
@testable import MemoirKit

// CF-71: resumption answers are current and grouped. "Where did I leave off" names the
// most recent thing worked on, not whatever matched a keyword hours ago.
// CF-72: accounting answers the question asked. One app's figure for one app's
// question; the total for a total question; never the whole table regardless.

/// The injected "now" for these suites: 18:00 *local* on the reference's local day.
/// Anchoring to local time keeps every seeded session inside one local day, so the
/// "today" windows in accounting templates hold in every timezone. 10:00 UTC would
/// sit on the far side of local midnight in UTC+13.
private let refNow: Date = {
    let dayStart = TestClock.localCalendar.startOfDay(for: TestClock.reference)
    return dayStart.addingTimeInterval(18 * 3_600)
}()

private func minutesBack(_ m: Double) -> Date { refNow.addingTimeInterval(-m * 60) }
private func hoursBack(_ h: Double) -> Date { refNow.addingTimeInterval(-h * 3_600) }

/// A stretch of seeded work: Fenwick in Xcode+Chrome, a Mail interlude, then Fenwick
/// again in Slack, ending at `refNow`.
private func seedMorning(_ store: Store) async throws -> Entity {
    let fenwick = Entity(
        id: TestID.stable("entity", "project", "Fenwick Migration"),
        kind: .project,
        title: "Fenwick Migration",
        source: .authored,
        aliases: ["fenwick", "FEN-42"],
        createdAt: hoursBack(2),
        updatedAt: hoursBack(2)
    )
    let sessions = [
        makeSession(appName: "Xcode", bundleID: "com.apple.dt.Xcode",
                    from: minutesBack(60), to: minutesBack(35)),
        makeSession(appName: "Chrome", bundleID: "com.google.Chrome",
                    from: minutesBack(35), to: minutesBack(20)),
        makeSession(appName: "Mail", bundleID: "com.apple.mail",
                    from: minutesBack(20), to: minutesBack(8)),
        makeSession(appName: "Slack", bundleID: "com.tinyspeck.slackmacgap",
                    from: minutesBack(8), to: refNow),
    ]
    let captures = [
        Fixtures.capture(text: "final class FenwickImporter {", app: "Xcode",
                         bundleID: "com.apple.dt.Xcode", windowTitle: "FenwickImporter.swift",
                         at: minutesBack(60), name: "m-xcode"),
        Fixtures.capture(text: "FEN-42 rate limiter rollout plan", app: "Chrome",
                         bundleID: "com.google.Chrome", windowTitle: "FEN-42 \u{2014} Jira",
                         at: minutesBack(35), name: "m-chrome"),
        Fixtures.capture(text: "Re: lunch thursday", app: "Mail",
                         bundleID: "com.apple.mail", windowTitle: "Inbox \u{2014} 3 unread",
                         at: minutesBack(20), name: "m-mail"),
        Fixtures.capture(text: "fenwick standup: rollout is green", app: "Slack",
                         bundleID: "com.tinyspeck.slackmacgap",
                         windowTitle: "#fenwick \u{2014} Slack",
                         at: minutesBack(8), name: "m-slack"),
    ]
    try await seed(store: store, captures: captures, entities: [fenwick], sessions: sessions)
    return fenwick
}

@Suite("CF-71 resumption answers")
struct ResumptionAnswerTests {

    @Test("CF-71 where-did-I-leave-off names the latest work, grouped")
    func leaveOffIsCurrentAndGrouped() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            _ = try await seedMorning(store)
            let brain = RulesOnlyBrain(store: store, now: { refNow })

            let answer = try await brain.answer(question: "where did I leave off", context: .empty)
            #expect(answer.text.contains("Fenwick Migration"),
                    "the span label, not an app name, is the answer")
            #expect(answer.text.contains("Slack"), "the app the span ended in is named")
            #expect(!answer.citedCaptureIDs.isEmpty, "a resumption answer carries evidence")

            // The answer describes the most recent span, not the stale Mail interlude.
            let firstLine = answer.text.components(separatedBy: "\n").first ?? ""
            #expect(firstLine.contains("Fenwick Migration"))
            #expect(!firstLine.contains("Mail"))
        }
    }

    @Test("CF-71 the earlier spans appear as history, newest first")
    func earlierSpansListed() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            _ = try await seedMorning(store)
            let brain = RulesOnlyBrain(store: store, now: { refNow })

            let answer = try await brain.answer(question: "catch me up on what I was doing", context: .empty)
            #expect(answer.text.contains("Before that"))
            #expect(answer.text.contains("Mail"), "the interlude is history, honestly listed")
        }
    }

    @Test("CF-71 an empty window widens instead of answering stale")
    func emptyWindowWidens() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            // The only work is 20 hours old; "an hour ago" has nothing.
            let fenwick = Entity(
                id: TestID.stable("entity", "project", "Fenwick Migration"),
                kind: .project, title: "Fenwick Migration",
                source: .authored, aliases: ["fenwick"],
                createdAt: hoursBack(21), updatedAt: hoursBack(21)
            )
            try await seed(
                store: store,
                captures: [Fixtures.capture(
                    text: "fenwick importer draft", app: "Xcode", bundleID: "com.apple.dt.Xcode",
                    windowTitle: "fenwick", at: hoursBack(20), name: "old-work"
                )],
                entities: [fenwick],
                sessions: [makeSession(appName: "Xcode", bundleID: "com.apple.dt.Xcode",
                                       from: hoursBack(20), to: hoursBack(19))]
            )
            let brain = RulesOnlyBrain(store: store, now: { refNow })
            let answer = try await brain.answer(question: "what was I doing an hour ago", context: .empty)
            #expect(answer.text.contains("Fenwick Migration"),
                    "widened to the last real work rather than claiming nothing exists")
        }
    }

    @Test("CF-71 yesterday means yesterday, not today's spans under yesterday's name")
    func yesterdayIsBounded() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            _ = try await seedMorning(store)   // today: Fenwick, Mail, Fenwick

            // Yesterday: a different project entirely.
            let invoices = Entity(
                id: TestID.stable("entity", "project", "Invoice Cleanup"),
                kind: .project, title: "Invoice Cleanup",
                source: .authored, aliases: ["invoices"],
                createdAt: hoursBack(30), updatedAt: hoursBack(30)
            )
            try await seed(
                store: store,
                captures: [Fixtures.capture(
                    text: "invoice cleanup pass two", app: "Numbers", bundleID: "com.apple.Numbers",
                    windowTitle: "Invoice Cleanup", at: hoursBack(26), name: "y-invoices"
                )],
                entities: [invoices],
                sessions: [makeSession(appName: "Numbers", bundleID: "com.apple.Numbers",
                                       from: hoursBack(26), to: hoursBack(25))]
            )
            let brain = RulesOnlyBrain(store: store, now: { refNow })
            let answer = try await brain.answer(question: "what was I doing yesterday", context: .empty)
            #expect(answer.text.contains("Invoice Cleanup"), "yesterday's work answers:\n\(answer.text)")
            let firstLine = answer.text.components(separatedBy: "\n").first ?? ""
            #expect(!firstLine.contains("Fenwick"), "today's spans must not lead a yesterday answer")
        }
    }

    @Test("CF-84 an answer about now says so when the record stopped hours ago")
    func staleRecordAnnouncesItself() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            // A record that STOPS eighteen hours before the question, exactly as it does
            // when capture dies quietly: paused, quit, or the Accessibility grant
            // invalidated by a rebuild and never re-given.
            let lastCapture = hoursBack(18)
            try await seed(
                store: store,
                captures: [Fixtures.capture(
                    text: "WhatsApp - Marco: are we still on for Thursday?",
                    app: "Google Chrome", bundleID: "com.google.Chrome",
                    windowTitle: "WhatsApp", at: lastCapture, name: "last-thing-seen"
                )],
                sessions: [makeSession(appName: "Google Chrome", bundleID: "com.google.Chrome",
                                       from: hoursBack(19), to: lastCapture)]
            )
            let brain = RulesOnlyBrain(store: store, now: { refNow })

            // Every question about the present must confess the gap. Being right about
            // yesterday while silent about today is what made the product look broken:
            // the answer was true, useless, and gave no clue why.
            for question in ["what was the last thing I did",
                             "where did I leave off",
                             "what did I do today"] {
                let answer = try await brain.answer(question: question, context: .empty)
                #expect(answer.text.localizedCaseInsensitiveContains("nothing has been captured since"),
                        "\"\(question)\" answered from an 18h-old record without saying so:\n\(answer.text)")
                #expect(answer.text.localizedCaseInsensitiveContains("accessibility"),
                        "the gap must come with the thing to go and check:\n\(answer.text)")
            }

            // A question about the past is not a claim about now, and must not be nagged.
            let lookup = try await brain.answer(question: "who is Marco", context: .empty)
            #expect(!lookup.text.localizedCaseInsensitiveContains("nothing has been captured since"),
                    "a lookup is not a claim about the present:\n\(lookup.text)")
        }
    }

    @Test("CF-71 no history at all is said plainly")
    func noHistoryIsHonest() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            let brain = RulesOnlyBrain(store: store, now: { refNow })
            let answer = try await brain.answer(question: "where did I leave off", context: .empty)
            #expect(answer.text.contains("not tracked"), "an empty memory refuses to invent a timeline")
        }
    }
}

@Suite("CF-72 accounting answers")
struct AccountingAnswerTests {

    @Test("CF-72 a one-app question gets that app's figure first")
    func appQuestionGetsAppFigure() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            _ = try await seedMorning(store)
            let brain = RulesOnlyBrain(store: store, now: { refNow })

            let answer = try await brain.answer(
                question: "how much time did I spend in chrome today", context: .empty
            )
            let firstLine = answer.text.components(separatedBy: "\n").first ?? ""
            #expect(firstLine.contains("Chrome"), "the asked app leads the answer")
            #expect(firstLine.contains("15 min"), "Chrome had exactly one 15-minute session")
            #expect(!firstLine.contains("Xcode"), "the rest of the table stays out of the headline")
        }
    }

    @Test("CF-72 how-long-have-I-been-working gets the total with bounds")
    func totalQuestionGetsTotal() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            _ = try await seedMorning(store)
            let brain = RulesOnlyBrain(store: store, now: { refNow })

            let answer = try await brain.answer(question: "how long have I been working", context: .empty)
            #expect(answer.text.contains("1h"), "60 minutes of seeded sessions")
            #expect(answer.text.contains("from"), "working bounds, not just a number")
        }
    }

    @Test("CF-72 summarise-my-day groups time by project, not only by app")
    func summaryGroupsByProject() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            _ = try await seedMorning(store)
            let brain = RulesOnlyBrain(store: store, now: { refNow })

            let answer = try await brain.answer(question: "summarise my day", context: .empty)
            #expect(answer.text.contains("Where it went"))
            #expect(answer.text.contains("Fenwick Migration"))
        }
    }

    @Test("CF-72 what-did-I-ship reports evidence, never claims deliverables")
    func shippedIsHonest() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            _ = try await seedMorning(store)
            let brain = RulesOnlyBrain(store: store, now: { refNow })

            let answer = try await brain.answer(question: "what did I ship today", context: .empty)
            #expect(answer.text.contains("Fenwick Migration"))
            #expect(answer.text.contains("not a claim about deliverables"),
                    "a screen cannot verify shipping; the answer must say what it is")
        }
    }

    @Test("CF-72 an app is matched by the word people actually say")
    func appMatchedByCommonWord() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            // The app is "Google Chrome"; nobody types that.
            try await seed(store: store, sessions: [
                makeSession(appName: "Google Chrome", bundleID: "com.google.Chrome",
                            from: minutesBack(60), to: minutesBack(30)),
                makeSession(appName: "Xcode", bundleID: "com.apple.dt.Xcode",
                            from: minutesBack(30), to: refNow),
            ])
            let brain = RulesOnlyBrain(store: store, now: { refNow })
            let answer = try await brain.answer(
                question: "how much time did I spend in chrome today", context: .empty
            )
            let firstLine = answer.text.components(separatedBy: "\n").first ?? ""
            #expect(firstLine.contains("Google Chrome"), "\"chrome\" must find Google Chrome:\n\(answer.text)")
            #expect(firstLine.contains("30 min"))
        }
    }

    @Test("CF-72 a fragment of a longer word is not an app match")
    func appMatchNeedsWholeWord() {
        let apps = ["Mail", "Google Chrome", "Notes"]
        #expect(RulesOnlyBrain.matchAppName("how long in gmail today", candidates: apps) == nil,
                "\"gmail\" is not Mail")
        #expect(RulesOnlyBrain.matchAppName("time spent in mail", candidates: apps) == "Mail")
        #expect(RulesOnlyBrain.matchAppName("how long in google today", candidates: apps) == nil,
                "\"google\" alone identifies no app")
    }

    @Test("CF-72 a busy today cannot starve yesterday's answer of its captures")
    func busyTodayDoesNotStarveYesterday() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            // Yesterday: one distinctive capture and a session.
            try await seed(
                store: store,
                captures: [Fixtures.capture(
                    text: "quarterly budget spreadsheet final", app: "Numbers",
                    bundleID: "com.apple.Numbers", windowTitle: "Quarterly Budget",
                    at: hoursBack(26), name: "y-budget"
                )],
                sessions: [makeSession(appName: "Numbers", bundleID: "com.apple.Numbers",
                                       from: hoursBack(26), to: hoursBack(25))]
            )
            // Today: 210 captures, more than the old fetch limit of 200, so a
            // newest-first LIMIT applied before the window filter would return only
            // today's rows and report yesterday as empty.
            for index in 0..<210 {
                try await store.insert(capture: Fixtures.capture(
                    text: "today filler number \(index) with enough text to be real",
                    app: "Safari", bundleID: "com.apple.Safari",
                    windowTitle: "filler \(index)",
                    at: hoursBack(8).addingTimeInterval(Double(index) * 60),
                    name: "t-filler-\(index)"
                ))
            }
            let brain = RulesOnlyBrain(store: store, now: { refNow })
            let answer = try await brain.answer(question: "summarise my day yesterday", context: .empty)
            #expect(answer.text.contains("Quarterly Budget"),
                    "yesterday's on-screen titles must survive a busy today:\n\(answer.text)")
        }
    }

    @Test("CF-72 an unknown app degrades to the total, not to silence")
    func unknownAppFallsBack() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            _ = try await seedMorning(store)
            let brain = RulesOnlyBrain(store: store, now: { refNow })

            let answer = try await brain.answer(
                question: "how much time did I spend in photoshop today", context: .empty
            )
            #expect(answer.text.contains("1h"), "the total is the honest fallback")
        }
    }
}
