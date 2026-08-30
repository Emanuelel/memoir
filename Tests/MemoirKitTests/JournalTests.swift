import Foundation
import Testing

import MemoirFixtures
@testable import MemoirKit

/// Tests for the journal, the authored half of the memory.
///
/// This is the most valuable data in the product: captures roll off and derived structures
/// compress, but what somebody wrote about their own life is meant to survive the whole decade.
/// It is also the only part a user would notice losing.
@Suite("Journal")
struct JournalTests {

    /// A work span with only the two fields the prompt reads.
    private func span(_ label: String, seconds: TimeInterval) -> WorkSpan {
        WorkSpan(
            label: label,
            entityID: nil,
            start: TestClock.reference,
            end: TestClock.reference.addingTimeInterval(seconds),
            seconds: seconds,
            apps: [],
            captureIDs: []
        )
    }

    private func entry(_ text: String) -> PushIntent {
        PushIntent(kind: .note, title: text, source: text)
    }

    @Test("Two entries with the same words on different days are two entries")
    func identicalEntriesOnDifferentDaysBothSurvive() async throws {
        // People write "Long day." more than once. Deriving a journal entry's identity from its
        // own text means the second one overwrites the first, and the first day silently loses
        // what was written in it.
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            let memory = MemoryService(store: store, extractors: [])
            let monday = TestClock.reference
            let thursday = TestClock.reference.addingTimeInterval(3 * 86_400)

            _ = try await memory.commitPush(entry("Long day."), now: monday)
            _ = try await memory.commitPush(entry("Long day."), now: thursday)

            let notes = try await store.entities(kind: .note, includeDeleted: false)
                .filter { $0.source == .authored }

            #expect(notes.count == 2, "the Monday entry was overwritten by the Thursday one")
        }
    }

    @Test("Case and punctuation do not make two entries one")
    func punctuationVariantsAreSeparateEntries() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            let memory = MemoryService(store: store, extractors: [])

            _ = try await memory.commitPush(entry("Tired"), now: TestClock.reference)
            _ = try await memory.commitPush(
                entry("tired."), now: TestClock.reference.addingTimeInterval(86_400)
            )

            let notes = try await store.entities(kind: .note, includeDeleted: false)
                .filter { $0.source == .authored }
            #expect(notes.count == 2)
        }
    }

    @Test("A journal entry keeps the day it was written on")
    func entryKeepsItsDay() async throws {
        // The pane groups by `updatedAt`, so an entry whose timestamp moves also moves days,
        // which is the same bug wearing a different symptom: Monday's writing appears under
        // Thursday.
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            let memory = MemoryService(store: store, extractors: [])
            let monday = TestClock.reference
            let thursday = monday.addingTimeInterval(3 * 86_400)

            _ = try await memory.commitPush(entry("Long day."), now: monday)
            _ = try await memory.commitPush(entry("Long day."), now: thursday)

            let notes = try await store.entities(kind: .note, includeDeleted: false)
                .filter { $0.source == .authored }
            let days = Set(notes.map { Calendar.current.startOfDay(for: $0.updatedAt) })
            #expect(days.count == 2, "both days should still have something written in them")
        }
    }

    @Test("The invitation says nothing about the user")
    func invitationDisclosesNothing() {
        // The band may invite and may never disclose. This is the sentence it says, and the test
        // exists because the tempting version ("you were on the listings again") is a
        // disclosure spoken to a room the user may not be alone in.
        let invitation = JournalPrompt.invitation
        #expect(invitation == "Anything you want to keep from today?")
        // No count, no streak, no reference to a day that was missed.
        for leak in ["yesterday", "days", "streak", "again", "still", "haven't", "last"] {
            #expect(
                !invitation.lowercased().contains(leak),
                "the invitation must not carry information about the user: '\(leak)'"
            )
        }
    }

    @Test("A quiet day still gets a prompt, never an empty composer")
    func quietDayStillHasAPrompt() {
        // The regression that mattered: no span over fifteen minutes returned nil, and the
        // composer went blank on the surface whose whole argument is that it never does.
        #expect(JournalPrompt.forToday(spans: []) == JournalPrompt.invitation)

        let brief = [span("Mail", seconds: 300)]
        #expect(JournalPrompt.forToday(spans: brief) == JournalPrompt.invitation)
    }

    @Test("A real day of work is named rather than asked about generically")
    func busyDayNamesTheThing() {
        let spans = [span("Mail", seconds: 600), span("Fenwick Migration", seconds: 5_400)]
        let prompt = JournalPrompt.forToday(spans: spans)
        #expect(prompt.contains("Fenwick Migration"), "it should name the longest stretch")
        #expect(prompt.contains("1h30"))
        #expect(prompt != JournalPrompt.invitation)
    }

    @Test("Quiet hours cover the invitation hour when the user sets them to")
    func quietHoursCoverTheInvitation() {
        // The invitation fires after 20:00. Somebody who has asked for silence from 20:00 has
        // already answered the question, and a second feature must not ask again.
        var quiet = QuietHours.default
        #expect(!quiet.covers(hour: 20), "the shipped default leaves the evening open")

        quiet.start = 20
        quiet.end = 7
        #expect(quiet.covers(hour: 20))
        #expect(quiet.covers(hour: 23))
    }

    @Test("A note pushed from the ask bar is also dated, not deduplicated")
    func askBarNotesAreAlsoDated() async throws {
        // The journal is not the only way in. "Remember: slept badly" typed into the ask bar goes
        // through the same push path, and losing the earlier one there is the same loss.
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            let memory = MemoryService(store: store, extractors: [])
            let first = try await memory.commitPush(entry("Slept badly"), now: TestClock.reference)
            let second = try await memory.commitPush(
                entry("Slept badly"), now: TestClock.reference.addingTimeInterval(86_400)
            )
            #expect(first.id != second.id)
        }
    }

    @Test("The same words in the same second are one entry, not two")
    func doubleSubmitIsCollapsed() async throws {
        // Return pressed twice. Two rows saying the same thing at the same instant is a bug the
        // user would see, and the second-precision id is what collapses it.
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            let memory = MemoryService(store: store, extractors: [])
            let now = TestClock.reference
            _ = try await memory.commitPush(entry("Long day."), now: now)
            _ = try await memory.commitPush(entry("Long day."), now: now)

            let notes = try await store.entities(kind: .note, includeDeleted: false)
                .filter { $0.source == .authored }
            #expect(notes.count == 1)
        }
    }

    @Test("Typing the same todo twice still makes one todo")
    func commitmentsStillDedupeByText() async throws {
        // The other half of the contract. Text-derived identity is *right* for a commitment
        // (typing "send the invoice" twice is one task, not two), so the fix must not turn
        // every re-typed todo into a duplicate.
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            let memory = MemoryService(store: store, extractors: [])

            _ = try await memory.commitPush(
                PushIntent(kind: .commitment, title: "Send the invoice", source: "Send the invoice"),
                now: TestClock.reference
            )
            _ = try await memory.commitPush(
                PushIntent(kind: .commitment, title: "send the invoice.", source: "send the invoice."),
                now: TestClock.reference.addingTimeInterval(86_400)
            )

            let todos = try await store.entities(kind: .commitment, includeDeleted: false)
            #expect(todos.count == 1, "one task, typed twice")
        }
    }
}
