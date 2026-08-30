//
//  EvalWorldTests.swift
//  The fixture the answer evals are graded against has to be the same fixture every time.
//

import Foundation
import Testing

import MemoirFixtures
@testable import MemoirKit

@Suite("CF-17b · The eval fixture is the same world every time")
struct EvalWorldTests {

    @Test("CF-17b seeding twice produces the same world, down to the arithmetic")
    func seedingIsDeterministic() async throws {
        let first = try await TestWorkspace.with { ws in
            try await EvalWorld.seed(into: try await ws.store())
        }
        let second = try await TestWorkspace.with { ws in
            try await EvalWorld.seed(into: try await ws.store())
        }

        // Ids are derived and dates are injected, so two builds must agree on everything,
        // not merely on the totals, which could match by luck.
        #expect(first.captureCount == second.captureCount)
        #expect(first.entityCount == second.entityCount)
        #expect(first.entitiesByKind == second.entitiesByKind)
        #expect(first.openCommitments == second.openCommitments)
        #expect(first.overdueCommitments == second.overdueCommitments)
        #expect(first.projects == second.projects)
        #expect(first.minutesByApp == second.minutesByApp)
    }

    @Test("CF-17b the seeded day's arithmetic is what Evals/answers.json says it is")
    func theFiguresTheExpectationsNameAreTheFiguresSeeded() async throws {
        let facts = try await TestWorkspace.with { ws in
            try await EvalWorld.seed(into: try await ws.store())
        }

        // These four numbers appear verbatim in `Evals/answers.json`. They are written here
        // as well, and not because two copies are better than one: this is the assertion that
        // fails when someone edits the session table and forgets that sixty-odd expectations
        // are arithmetic over it. `facts.json` is the copy a reader checks against; this is
        // the copy that goes red.
        #expect(facts.totalMinutes == 193)              // 3h 13m
        #expect(facts.minutesByApp["Google Chrome"] == 98)  // 1h 38m
        #expect(facts.minutesByApp["Claude"] == 55)
        #expect(facts.minutesByApp["Obsidian"] == 25)
        #expect(facts.topApp == "Google Chrome")

        // Chrome wins on the SUM and loses on the longest single session, which is the whole
        // reason the day is cut this way: a superlative that picks the longest row rather than
        // the biggest column gets Claude, and gets it wrong.
        let longestSingleSpan = EvalWorld.spans.max { $0.minutes < $1.minutes }
        #expect(longestSingleSpan?.app.name == "Claude")

        // Exactly one commitment is past due, and it is the invoice. "What's overdue" is
        // graded on that.
        #expect(facts.overdueCommitments.count == 1)
        #expect(facts.overdueCommitments.first?.contains("February invoice") == true)
        #expect(facts.openCommitments.count == 8)
    }

    @Test("CF-17b nothing in the fixture world names anything real")
    func theWorldIsInvented() async throws {
        // The eval corpus used to be one person's browsing record. This is the assertion that
        // notices if any of it comes back: in a capture, a window title or an entity title.
        let retired = ["hgiggslied", "motionsites", "higgsfield", "screenmind",
                       "openwhispr", "ayushh0110", "mvanhorn", "isaac", "heytaby"]
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            _ = try await EvalWorld.seed(into: store)
            let haystack = try await store.captures(since: .distantPast, limit: 5_000)
                .map { ($0.text + " " + ($0.windowTitle ?? "")) }
                .joined(separator: " ")
                .lowercased()
            for name in retired {
                #expect(!haystack.contains(name), "the fixture world names \(name)")
            }
        }
    }
}
