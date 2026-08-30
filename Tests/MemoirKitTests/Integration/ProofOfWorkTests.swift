import Foundation
import Testing
import MemoirFixtures
@testable import MemoirKit

// CF-75: write-back is a reviewed proposal, never a sync. Drafting writes nothing;
// only an explicit accept writes; the write lands only inside <vault>/Memoir/.
// CF-76: the timesheet is arithmetic with receipts. Per day, per thing, every line
// traceable, unlabelled time honestly under its app, totals that add up.

/// The injected "now": 18:00 *local* on the reference's local day. Timesheets bucket
/// by local calendar day, so seeds anchored to UTC would straddle midnight in some
/// timezones and change the line count. Local anchoring makes the day structure the
/// same everywhere.
private let refNow: Date = {
    let dayStart = TestClock.localCalendar.startOfDay(for: TestClock.reference)
    return dayStart.addingTimeInterval(18 * 3_600)
}()

private func hoursBack(_ h: Double) -> Date { refNow.addingTimeInterval(-h * 3_600) }

/// Two seeded local days: yesterday fully Fenwick (2h, 17:00-19:00), today one hour
/// Fenwick (16:00-17:00) + 30 min Mail (17:00-17:30).
private func seedTwoDays(_ store: Store) async throws {
    let fenwick = Entity(
        id: TestID.stable("entity", "project", "Fenwick Migration"),
        kind: .project, title: "Fenwick Migration",
        source: .authored, aliases: ["fenwick"],
        createdAt: hoursBack(48), updatedAt: hoursBack(48)
    )
    let sessions = [
        makeSession(appName: "Xcode", bundleID: "com.apple.dt.Xcode",
                    from: hoursBack(25), to: hoursBack(23)),
        makeSession(appName: "Xcode", bundleID: "com.apple.dt.Xcode",
                    from: hoursBack(2), to: hoursBack(1)),
        makeSession(appName: "Mail", bundleID: "com.apple.mail",
                    from: hoursBack(1), to: hoursBack(0.5)),
    ]
    let captures = [
        Fixtures.capture(text: "fenwick importer, day before", app: "Xcode",
                         bundleID: "com.apple.dt.Xcode", windowTitle: "fenwick",
                         at: hoursBack(25), name: "ts-old"),
        Fixtures.capture(text: "fenwick importer, today", app: "Xcode",
                         bundleID: "com.apple.dt.Xcode", windowTitle: "fenwick",
                         at: hoursBack(2), name: "ts-new"),
        Fixtures.capture(text: "inbox triage", app: "Mail",
                         bundleID: "com.apple.mail", windowTitle: "Inbox",
                         at: hoursBack(1), name: "ts-mail"),
    ]
    try await seed(store: store, captures: captures, entities: [fenwick], sessions: sessions)
}

@Suite("CF-76 timesheet")
struct TimesheetTests {

    @Test("CF-76 per-day, per-project lines with evidence and honest totals")
    func timesheetShape() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            let memory = MemoryService(store: store, extractors: [RuleExtractor()])
            try await seedTwoDays(store)

            let sheet = try await memory.timesheet(
                from: hoursBack(36), to: refNow
            )
            #expect(sheet.lines.count == 3, "two Fenwick days plus one Mail line")

            let days = Set(sheet.lines.map(\.day))
            #expect(days.count == 2, "lines bucket by day")

            let fenwickToday = sheet.lines.first {
                $0.label == "Fenwick Migration" && $0.day == TestClock.localCalendar.startOfDay(for: refNow)
            }
            #expect(abs((fenwickToday?.seconds ?? 0) - 3_600) < 1)
            #expect(fenwickToday?.captureIDs.isEmpty == false, "every project line carries evidence")

            let mail = sheet.lines.first { $0.label == "Mail" }
            #expect(mail?.entityID == nil, "unlabelled time claims no project")

            // The total is the sum of its parts: 2h + 1h + 30m.
            #expect(abs(sheet.totalSeconds - (2 * 3_600 + 3_600 + 1_800)) < 2)
        }
    }

    @Test("CF-76 the rendered markdown says what attribution rests on")
    func markdownIsHonest() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            let memory = MemoryService(store: store, extractors: [RuleExtractor()])
            try await seedTwoDays(store)
            let brain = RulesOnlyBrain(store: store, now: { refNow })

            let answer = try await brain.answer(question: "give me my timesheet", context: .empty)
            #expect(answer.text.contains("Fenwick Migration"))
            #expect(answer.text.contains("Total:"))
            #expect(answer.text.contains("never guessed into a project"),
                    "the attribution method is stated, not implied")
            #expect(!answer.citedCaptureIDs.isEmpty)
        }
    }

    @Test("CF-76 the weekly review covers time, entities and commitments")
    func weeklyReview() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            let memory = MemoryService(store: store, extractors: [RuleExtractor()])
            try await seedTwoDays(store)
            try await store.upsert(entity: makeEntity(
                kind: .commitment, title: "Send the revised invoice",
                dueAt: hoursBack(24), at: hoursBack(48)
            ))

            let review = try await memory.weeklyReview(
                from: hoursBack(168), to: refNow, now: refNow
            )
            #expect(review.contains("Where the time went"))
            #expect(review.contains("Fenwick Migration"))
            #expect(review.contains("Send the revised invoice"))
            #expect(review.contains("overdue"), "a past-due commitment is called out")
            #expect(review.contains("measured, not estimated"))
        }
    }
}

@Suite("CF-75 reviewed write-back")
struct WriteBackTests {

    private func makeVault(in ws: TestWorkspace) throws -> URL {
        let root = ws.root.appendingPathComponent("vault", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "my own note".write(
            to: root.appendingPathComponent("mine.md"), atomically: true, encoding: .utf8)
        return root
    }

    @Test("CF-75 drafting writes nothing anywhere")
    func draftingIsPureRead() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            let memory = MemoryService(store: store, extractors: [RuleExtractor()])
            try await seedTwoDays(store)
            let vault = try makeVault(in: ws)

            let before = try FileManager.default
                .subpathsOfDirectory(atPath: vault.path).sorted()
            let draft = try await memory.dailyNoteDraft(
                for: refNow, now: refNow
            )
            let after = try FileManager.default
                .subpathsOfDirectory(atPath: vault.path).sorted()

            #expect(!draft.isEmpty)
            #expect(draft.contains("Fenwick Migration"))
            #expect(before == after, "a proposal is a string, not a file")
        }
    }

    @Test("CF-75 accept writes exactly one file, only inside Memoir/")
    func acceptWritesOnlyInPipFolder() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            let memory = MemoryService(store: store, extractors: [RuleExtractor()])
            try await seedTwoDays(store)
            let vault = try makeVault(in: ws)

            let draft = try await memory.dailyNoteDraft(
                for: refNow, now: refNow
            )
            let written = try VaultWriteBack.write(
                draft: draft, vaultRoot: vault, day: refNow
            )

            #expect(written.path.contains("/Memoir/"), "the write lands in Memoir's folder and nowhere else")
            // Expected name computed the same way the writer computes it (local
            // calendar day), so the assertion holds in every timezone.
            let comps = TestClock.localCalendar.dateComponents([.year, .month, .day], from: refNow)
            let expectedName = String(format: "%04d-%02d-%02d.md", comps.year!, comps.month!, comps.day!)
            #expect(written.lastPathComponent == expectedName)
            let content = try String(contentsOf: written, encoding: .utf8)
            #expect(content == draft, "what was reviewed is what was written")

            // The user's own note is untouched.
            let mine = try String(
                contentsOf: vault.appendingPathComponent("mine.md"), encoding: .utf8)
            #expect(mine == "my own note")
        }
    }

    @Test("CF-75 what Memoir wrote is never read back as memory")
    func writtenNotesAreNotReimported() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            let memory = MemoryService(store: store, extractors: [RuleExtractor()])
            try await seedTwoDays(store)
            let vault = try makeVault(in: ws)

            let draft = try await memory.dailyNoteDraft(
                for: refNow, now: refNow
            )
            _ = try VaultWriteBack.write(draft: draft, vaultRoot: vault, day: refNow)

            let summary = try await memory.importVault(at: vault, now: refNow)
            #expect(summary.notesRead == 1, "only the user's own note; Memoir/ is skipped on import")
        }
    }

    @Test("CF-75 a missing vault refuses the write")
    func missingVaultRefuses() async throws {
        try await TestWorkspace.with { ws in
            #expect(throws: MemoirError.self) {
                try VaultWriteBack.write(
                    draft: "anything",
                    vaultRoot: ws.root.appendingPathComponent("nope"),
                    day: TestClock.reference
                )
            }
        }
    }
}
