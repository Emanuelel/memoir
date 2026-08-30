//  CF-51 · nothing is written without confirmation.
//
//  The parse and the commit are two calls on purpose. Everything Memoir inferred up to now
//  could be wrong and correctable; something it wrote because it misunderstood you is wrong
//  and *authoritative*, which is worse. So a proposal has to be visible and rejectable
//  before it becomes a memory.

import Foundation
import Testing

import MemoirFixtures
@testable import MemoirKit

@Suite("CF-51 · nothing is written without confirmation")
struct PushCommitTests {

    @Test("CF-51 previewing writes nothing at all")
    func previewIsInert() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            let memory = MemoryService(store: store, extractors: [RuleExtractor()])

            let before = try await store.entities(kind: nil, includeDeleted: true).count
            let intent = memory.previewPush("remind me to send the invoice friday",
                                            now: TestClock.reference)
            #expect(intent != nil)
            let after = try await store.entities(kind: nil, includeDeleted: true).count
            #expect(after == before, "previewing must not write")
        }
    }

    @Test("CF-51 committing writes exactly one authored entity")
    func commitWritesAuthored() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            let memory = MemoryService(store: store, extractors: [RuleExtractor()])

            let intent = try #require(memory.previewPush("remind me to send the invoice friday",
                                                         now: TestClock.reference))
            let saved = try await memory.commitPush(intent, now: TestClock.reference)

            #expect(saved.source == .authored)
            #expect(saved.kind == .commitment)
            #expect(saved.title.contains("invoice"))
            #expect(saved.dueAt != nil)

            let stored = try #require(try await store.entity(id: saved.id))
            // CF-55: the flag survives the round trip through SQLite.
            #expect(stored.source == .authored)
            #expect(stored.title == saved.title)
        }
    }

    @Test("CF-51 accepting twice makes one row, not two")
    func commitIsIdempotent() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            let memory = MemoryService(store: store, extractors: [RuleExtractor()])

            // "Did my Enter register?" is a question people answer by pressing Enter again.
            let intent = try #require(memory.previewPush("remind me to call the accountant tomorrow at 10",
                                                         now: TestClock.reference))
            _ = try await memory.commitPush(intent, now: TestClock.reference)
            _ = try await memory.commitPush(intent, now: TestClock.reference)

            let rows = try await store.entities(kind: .commitment, includeDeleted: true)
            #expect(rows.count == 1, "an accepted proposal must be idempotent, got \(rows.count)")
        }
    }

    @Test("CF-56 a completed push is never resurrected by extraction")
    func completionIsPermanent() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            let memory = MemoryService(store: store, extractors: [RuleExtractor()])

            let intent = try #require(memory.previewPush("remind me to send the invoice friday",
                                                         now: TestClock.reference))
            let saved = try await memory.commitPush(intent, now: TestClock.reference)
            try await memory.completePush(entityID: saved.id, at: TestClock.hours(2))

            // Now let extraction run over text that would happily propose the same thing.
            try await store.insert(capture: CaptureEvent(
                ts: TestClock.reference,
                appBundleID: "com.tinyspeck.slackmacgap", appName: "Slack",
                windowTitle: "invoices",
                text: "I'll send the invoice friday, promise.",
                textHash: "resurrect"))
            _ = try? await memory.consolidate(since: TestClock.reference.addingTimeInterval(-3600),
                                              now: TestClock.reference)

            // Done is `completed_at` (schema v5), not a delete: the row stays visible,
            // struck through, and reopenable, while extraction can never bring it back
            // to the open list.
            let row = try #require(try await store.entity(id: saved.id))
            #expect(row.completedAt == TestClock.hours(2), "a ticked-off commitment must stay ticked off")
            #expect(!row.deleted, "completing is not forgetting: the row is still shown")
            let open = try await store.openCommitments(now: TestClock.hours(6))
            #expect(!open.contains { $0.id == saved.id }, "a done item resurfaced as open")
        }
    }

    @Test("CF-52 a phrase Memoir cannot parse is refused, not guessed at")
    func unparseableIsNil() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            let memory = MemoryService(store: store, extractors: [RuleExtractor()])
            // A question is not a push, and neither is noise. Both must return nil so the UI
            // can say "I did not catch that" rather than storing something invented.
            #expect(memory.previewPush("remind me what I was working on", now: TestClock.reference) == nil)
            #expect(memory.previewPush("asdfghjkl", now: TestClock.reference) == nil)
            #expect(memory.previewPush("", now: TestClock.reference) == nil)
        }
    }
}
