//
//  RemindersSyncTests.swift
//  Authored commitments, pushed out to Apple Reminders.
//
//  ─────────────────────────────────────────────────────────────────────────────
//  No EventKit here, and that is the point rather than a shortcut. The rules being
//  tested are the ones that can hurt somebody: a guess landing in their task list,
//  a duplicate arriving on every pass, a denied permission taking a commitment down
//  with it. And rules that can only run behind a TCC prompt never actually run.
//  `EventKitSink` is compiled by the build and exercised by hand; everything in
//  this file is the policy that decides whether it is ever called.
//
//  Every test runs inside `TestWorkspace.with`, even the ones with no store: the
//  degradation paths log, and a log outside the workspace lands in the user's real
//  ~/Library/Application Support/Memoir.
//  ─────────────────────────────────────────────────────────────────────────────
//

import Foundation
import Testing

import MemoirFixtures
@testable import MemoirKit

// MARK: - The fake sink

/// A `ReminderSink` that records everything and can be made to fail on demand.
///
/// Keyed by `externalID`, exactly like the real thing, because that is the property
/// idempotence rests on: two writes with one key must leave one reminder.
private final class FakeReminderSink: ReminderSink, @unchecked Sendable {

    /// One reminder as the sink sees it.
    struct Row: Sendable, Equatable {
        var title: String
        var dueAt: Date?
        var isCompleted: Bool
    }

    private let lock = NSLock()
    private var rows: [String: Row] = [:]
    private var upserts = 0
    private var completions = 0
    private var prepares = 0
    private var failure: (any Error)?
    /// Which ids fail. Nil means every id fails.
    private var failingIDs: Set<String>?
    /// What the permission check throws. Nil means Memoir may write.
    private var accessFailure: (any Error)?

    // MARK: ReminderSink

    func upsert(title: String, dueAt: Date?, externalID: String) async throws -> String {
        try lock.withLock {
            upserts += 1
            if let error = configuredFailure(for: externalID) { throw error }
            rows[externalID] = Row(
                title: title,
                dueAt: dueAt,
                isCompleted: rows[externalID]?.isCompleted ?? false
            )
            return "fake-\(externalID)"
        }
    }

    func complete(externalID: String) async throws {
        try lock.withLock {
            completions += 1
            if let error = configuredFailure(for: externalID) { throw error }
            rows[externalID]?.isCompleted = true
        }
    }

    func prepareForWriting() async throws {
        try lock.withLock {
            prepares += 1
            if let accessFailure { throw accessFailure }
        }
    }

    // MARK: Inspection

    /// How many distinct reminders exist. The number idempotence is about.
    var reminderCount: Int { lock.withLock { rows.count } }

    /// How many times permission was asked for.
    var prepareCount: Int { lock.withLock { prepares } }

    /// Every reminder, keyed by external id.
    var allRows: [String: Row] { lock.withLock { rows } }

    /// The reminder for one entity, or nil.
    func row(for entity: Entity) -> Row? {
        lock.withLock { rows[RemindersSync.externalID(for: entity)] }
    }

    /// How many times `upsert` was reached, successes and failures alike.
    var upsertCount: Int { lock.withLock { upserts } }

    /// How many times `complete` was reached.
    var completeCount: Int { lock.withLock { completions } }

    // MARK: Control

    /// Every call throws until ``stopFailing()``.
    func failEverything(with error: any Error = ReminderSyncError.accessDenied("No Reminders access in this test.")) {
        lock.withLock {
            failure = error
            failingIDs = nil
        }
    }

    /// Only calls for these external ids throw.
    func failOnly(_ ids: Set<String>, with error: any Error = ReminderSyncError.writeFailed("Rejected in this test.")) {
        lock.withLock {
            failure = error
            failingIDs = ids
        }
    }

    /// Back to healthy.
    func stopFailing() {
        lock.withLock {
            failure = nil
            failingIDs = nil
        }
    }

    /// The permission check throws, exactly as `EventKitSink` does when TCC says no or when
    /// macOS never asked.
    func refuseAccess(with error: any Error) {
        lock.withLock { accessFailure = error }
    }

    /// Must be called with the lock already held.
    private func configuredFailure(for externalID: String) -> (any Error)? {
        guard let failure else { return nil }
        guard let failingIDs else { return failure }
        return failingIDs.contains(externalID) ? failure : nil
    }
}

// MARK: - Rows

/// An authored commitment, exactly as `MemoryService.commitPush` writes one.
private func authoredCommitment(
    title: String,
    dueAt: Date? = nil,
    deleted: Bool = false,
    id: ID? = nil
) -> Entity {
    Entity(
        id: id ?? TestID.stable("reminders", "authored", title),
        kind: .commitment,
        title: title,
        detail: nil,
        dueAt: dueAt,
        confidence: 1.0,
        pinned: false,
        corrected: false,
        deleted: deleted,
        source: .authored,
        createdAt: TestClock.reference,
        updatedAt: TestClock.reference
    )
}

/// The same commitment as something Memoir guessed at instead.
private func inferredCommitment(title: String, dueAt: Date? = nil) -> Entity {
    Entity(
        id: TestID.stable("reminders", "inferred", title),
        kind: .commitment,
        title: title,
        detail: nil,
        dueAt: dueAt,
        confidence: 0.6,
        pinned: false,
        corrected: false,
        deleted: false,
        source: .inferred,
        createdAt: TestClock.reference,
        updatedAt: TestClock.reference
    )
}

// MARK: - Tests

@Suite("Reminders sync · authored commitments reach the phone")
struct RemindersSyncTests {

    /// Friday 17:00 local, the convention `MemoryDateResolver` produces for a bare weekday.
    private static let friday = TestClock.local(2026, 3, 20, 17, 0)

    // MARK: What syncs

    @Test("An authored commitment is written to the sink with its own words and its own date")
    func authoredSyncs() async throws {
        try await TestWorkspace.with { _ in
            let sink = FakeReminderSink()
            let sync = RemindersSync(sink: sink)
            let entity = authoredCommitment(title: "send the invoice", dueAt: Self.friday)

            let outcome = try await sync.push(entity, enabled: true)

            #expect(outcome == .synced(reminderID: "fake-\(RemindersSync.externalID(for: entity))"))
            let row = try #require(sink.row(for: entity))
            #expect(row.title == "send the invoice", "the reminder must carry the user's own words")
            #expect(row.dueAt == Self.friday)
            #expect(row.isCompleted == false)

            // CF-2. EventKit writes to a local database; whether it travels is iCloud's
            // business, under the user's account. Memoir itself must still open nothing.
            assertNoNetwork()
        }
    }

    @Test("CF-54 an inferred commitment never reaches the user's task list")
    func inferredNeverSyncs() async throws {
        try await TestWorkspace.with { _ in
            let sink = FakeReminderSink()
            let sync = RemindersSync(sink: sink)

            let outcome = try await sync.push(inferredCommitment(title: "chase elena for the numbers"),
                                              enabled: true)

            #expect(outcome == .skipped(.notAuthored))
            #expect(sink.upsertCount == 0, "a guess must not even be offered to the sink")
            #expect(sink.reminderCount == 0)
        }
    }

    @Test("Sync does nothing unless the call opts in")
    func offByDefault() async throws {
        try await TestWorkspace.with { _ in
            let sink = FakeReminderSink()
            let sync = RemindersSync(sink: sink)
            let entity = authoredCommitment(title: "book the flights", dueAt: Self.friday)

            // The bare call is the one a caller writes without thinking about it.
            let byDefault = try await sync.push(entity)
            let explicitlyOff = try await sync.push(entity, enabled: false)
            #expect(byDefault == .skipped(.syncDisabled))
            #expect(explicitlyOff == .skipped(.syncDisabled))
            #expect(sink.upsertCount == 0)
            #expect(sink.reminderCount == 0)
        }
    }

    @Test("Notes and empty titles are not tasks")
    func onlyCommitmentsSync() async throws {
        try await TestWorkspace.with { _ in
            let sink = FakeReminderSink()
            let sync = RemindersSync(sink: sink)

            var note = authoredCommitment(title: "the wifi password is on the fridge")
            note.kind = .note
            let noteOutcome = try await sync.push(note, enabled: true)
            #expect(noteOutcome == .skipped(.notACommitment))

            var blank = authoredCommitment(title: "blank")
            blank.title = "   "
            let blankOutcome = try await sync.push(blank, enabled: true)
            #expect(blankOutcome == .skipped(.emptyTitle))

            #expect(sink.upsertCount == 0)
        }
    }

    // MARK: Idempotence

    @Test("Syncing the same commitment twice leaves one reminder")
    func idempotent() async throws {
        try await TestWorkspace.with { _ in
            let sink = FakeReminderSink()
            let sync = RemindersSync(sink: sink)
            let entity = authoredCommitment(title: "call the accountant", dueAt: Self.friday)

            let first = try await sync.push(entity, enabled: true)
            let second = try await sync.push(entity, enabled: true)

            #expect(first != second, "the second pass has nothing left to write")
            #expect(second == .unchanged)
            #expect(sink.reminderCount == 1, "got \(sink.reminderCount) reminders for one commitment")
            #expect(sink.upsertCount == 1, "an unchanged commitment must not be rewritten")
        }
    }

    @Test("Idempotence survives a relaunch, because the key is derived and not remembered")
    func idempotentAcrossProcesses() async throws {
        try await TestWorkspace.with { _ in
            let sink = FakeReminderSink()
            let entity = authoredCommitment(title: "renew the domain", dueAt: Self.friday)

            _ = try await RemindersSync(sink: sink).push(entity, enabled: true)
            // A second `RemindersSync` knows nothing about the first one. That is exactly
            // the state after a restart, and the reminder must still be the same reminder.
            _ = try await RemindersSync(sink: sink).push(entity, enabled: true)

            #expect(sink.reminderCount == 1, "got \(sink.reminderCount) reminders after a relaunch")
            #expect(sink.upsertCount == 2, "the fresh sync has to write once to find out")
        }
    }

    @Test("A retitled or rescheduled commitment updates its reminder in place")
    func editUpdatesInPlace() async throws {
        try await TestWorkspace.with { _ in
            let sink = FakeReminderSink()
            let sync = RemindersSync(sink: sink)
            let id = TestID.stable("reminders", "edited")

            var entity = authoredCommitment(title: "send the invoice", dueAt: Self.friday, id: id)
            _ = try await sync.push(entity, enabled: true)

            entity.title = "send the invoice to elena"
            entity.dueAt = TestClock.local(2026, 3, 23, 9, 0)
            let outcome = try await sync.push(entity, enabled: true)

            #expect(outcome != .unchanged, "a changed commitment must be written again")
            #expect(sink.reminderCount == 1, "an edit must not leave the old reminder nagging")
            let row = try #require(sink.row(for: entity))
            #expect(row.title == "send the invoice to elena")
            #expect(row.dueAt == TestClock.local(2026, 3, 23, 9, 0))
        }
    }

    // MARK: Completion

    @Test("CF-56 ticking a commitment off at the desk ticks off the reminder")
    func completionPropagates() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            let memory = MemoryService(store: store, extractors: [RuleExtractor()])
            let sink = FakeReminderSink()
            let sync = RemindersSync(sink: sink)

            let intent = try #require(memory.previewPush("remind me to send the invoice friday",
                                                          now: TestClock.reference))
            let saved = try await memory.commitPush(intent, now: TestClock.reference)
            _ = try await sync.push(saved, enabled: true)
            #expect(sink.row(for: saved)?.isCompleted == false)

            // `completePush` is a soft delete, so this is what "I did it" looks like from
            // the sync's side. Leaving the reminder open would have the phone keep asking
            // about something already ticked off.
            try await memory.completePush(entityID: saved.id)
            let done = try #require(try await store.entity(id: saved.id))

            let outcome = try await sync.push(done, enabled: true)

            #expect(outcome == .completed)
            #expect(sink.row(for: saved)?.isCompleted == true)
            #expect(sink.reminderCount == 1, "completing must not create a second reminder")
        }
    }

    // MARK: Degradation

    @Test("A sink that refuses never costs the local commitment")
    func failureKeepsLocalState() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            let memory = MemoryService(store: store, extractors: [RuleExtractor()])
            let sink = FakeReminderSink()
            sink.failEverything()
            let sync = RemindersSync(sink: sink)

            let intent = try #require(memory.previewPush("remind me to call the accountant tomorrow at 10",
                                                          now: TestClock.reference))
            let saved = try await memory.commitPush(intent, now: TestClock.reference)

            let outcome = try await sync.push(saved, enabled: true)

            guard case .failed(let reason) = outcome else {
                Issue.record("a denied sink must degrade, got \(outcome)")
                return
            }
            #expect(!reason.isEmpty, "a failure the user cannot read is not a failure they can fix")

            // The whole promise: the reminder is a copy, the memory is the product.
            let row = try #require(try await store.entity(id: saved.id))
            #expect(row.title == saved.title)
            #expect(row.dueAt == saved.dueAt)
            #expect(row.source == .authored)
            #expect(row.deleted == false)
            #expect(sink.reminderCount == 0)
        }
    }

    @Test("A failed sync is retried, not remembered as done")
    func failureIsNotCached() async throws {
        try await TestWorkspace.with { _ in
            let sink = FakeReminderSink()
            let sync = RemindersSync(sink: sink)
            let entity = authoredCommitment(title: "file the vat return", dueAt: Self.friday)

            sink.failEverything()
            _ = try await sync.push(entity, enabled: true)

            // Permission granted, or the machine came back. Caching the failure would make
            // this second pass return `.unchanged` and lose the reminder silently, which is
            // the worst of the available outcomes: no error and no reminder.
            sink.stopFailing()
            let outcome = try await sync.push(entity, enabled: true)

            #expect(outcome == .synced(reminderID: "fake-\(RemindersSync.externalID(for: entity))"))
            #expect(sink.row(for: entity)?.title == "file the vat return")
        }
    }

    @Test("One bad row does not cost the rest of the batch")
    func batchSurvivesOneFailure() async throws {
        try await TestWorkspace.with { _ in
            let sink = FakeReminderSink()
            let sync = RemindersSync(sink: sink)

            let good = authoredCommitment(title: "book the rehearsal room", dueAt: Self.friday)
            let bad = authoredCommitment(title: "renew the insurance", dueAt: Self.friday)
            let guess = inferredCommitment(title: "look at the pricing page")
            sink.failOnly([RemindersSync.externalID(for: bad)])

            let outcomes = try await sync.push([good, bad, guess], enabled: true)

            #expect(outcomes.count == 3)
            #expect(outcomes[0] == .synced(reminderID: "fake-\(RemindersSync.externalID(for: good))"))
            if case .failed = outcomes[1] {} else { Issue.record("expected the middle row to fail, got \(outcomes[1])") }
            #expect(outcomes[2] == .skipped(.notAuthored))
            #expect(sink.row(for: good) != nil, "a later failure must not undo an earlier write")
            #expect(sink.reminderCount == 1)
            assertNoNetwork()
        }
    }

    @Test("Forgetting an entity forces the next push to write again")
    func forgetForcesRewrite() async throws {
        try await TestWorkspace.with { _ in
            let sink = FakeReminderSink()
            let sync = RemindersSync(sink: sink)
            let entity = authoredCommitment(title: "post the contract", dueAt: Self.friday)

            _ = try await sync.push(entity, enabled: true)
            let cached = try await sync.push(entity, enabled: true)
            #expect(cached == .unchanged)

            // The user deleted the reminder on their phone. Memoir's cache still says it is
            // up to date, and this is the way back.
            await sync.forget(entity.id)
            let outcome = try await sync.push(entity, enabled: true)

            #expect(outcome != .unchanged)
            #expect(sink.upsertCount == 2)
            #expect(sink.reminderCount == 1)
        }
    }

    // MARK: - The switch

    @Test("Sync is off in a fresh config, and off in a config file written before it existed")
    func settingDefaultsToOff() throws {
        #expect(RemindersConfig().syncToReminders == false)

        // The shape of every config.json on disk today. Decoding it as "on" would have an
        // upgrade start writing into somebody's task list without them asking.
        let older = try JSONDecoder().decode(RemindersConfig.self, from: Data("{}".utf8))
        #expect(older.syncToReminders == false)

        let turnedOn = try JSONDecoder().decode(
            RemindersConfig.self, from: Data(#"{"syncToReminders":true}"#.utf8))
        #expect(turnedOn.syncToReminders == true)
    }

    @Test("The setting is what decides, and its default writes nothing")
    func settingDrivesSync() async throws {
        try await TestWorkspace.with { _ in
            let sink = FakeReminderSink()
            let sync = RemindersSync(sink: sink)
            let entity = authoredCommitment(title: "send the deposit", dueAt: Self.friday)

            let off = try await sync.push(entity, enabled: RemindersConfig().syncToReminders)
            #expect(off == .skipped(.syncDisabled))
            #expect(sink.upsertCount == 0, "the shipped default must not reach the sink at all")

            let on = try await sync.push(
                entity, enabled: RemindersConfig(syncToReminders: true).syncToReminders)
            #expect(on == .synced(reminderID: "fake-\(RemindersSync.externalID(for: entity))"))
        }
    }

    // MARK: - Permission

    @Test("A refusal macOS never asked about is not a refusal")
    func silentRefusalIsNotADenial() throws {
        // The trap: `requestFullAccessToReminders` calls back false with no error and no
        // prompt shown, leaving the status at `.notDetermined`. Reading that as a denial
        // sends the user to a pane that does not list Memoir, so there is nothing there to
        // un-deny and the message is worse than useless.
        let trap = RemindersPermissions.failure(granted: false, status: .notDetermined)
        guard case .notPrompted(let message)? = trap else {
            Issue.record("an unprompted refusal must not be reported as a denial, got \(String(describing: trap))")
            return
        }
        #expect(message.contains(RemindersPermissions.pane), "the message has to name the pane")
        #expect(message.contains("did not ask"), "the message has to say macOS never asked")

        // A real no is a different error with a different sentence.
        guard case .accessDenied(let denied)? =
                RemindersPermissions.failure(granted: false, status: .denied) else {
            Issue.record("a genuine denial must stay a denial")
            return
        }
        #expect(denied != message)
        #expect(denied.contains(RemindersPermissions.pane))
    }

    @Test("Every permission answer produces exactly one verdict")
    func permissionVerdictIsTotal() throws {
        for grant in RemindersPermissions.Grant.allCases {
            #expect(RemindersPermissions.failure(granted: true, status: grant) == nil,
                    "a granted request is granted whatever the status says, failed on \(grant)")

            let refused = RemindersPermissions.failure(granted: false, status: grant)
            let described = try #require(refused?.localizedDescription,
                                         "a refusal with status \(grant) produced no message")
            #expect(!described.isEmpty)
            #expect(described.contains("Reminders"),
                    "a message that never says Reminders cannot be acted on: \(described)")
        }
    }

    @Test("A permission that cannot be got is reported, not thrown, and writes nothing")
    func prepareReportsTheProblem() async throws {
        try await TestWorkspace.with { _ in
            let sink = FakeReminderSink()
            sink.refuseAccess(with: ReminderSyncError.notPrompted(RemindersPermissions.notPromptedMessage))
            let sync = RemindersSync(sink: sink)

            let problem = try #require(await sync.prepare())

            #expect(problem == RemindersPermissions.notPromptedMessage)
            #expect(sink.prepareCount == 1)
            #expect(sink.reminderCount == 0, "asking for permission must never write anything")
            assertNoNetwork()
        }
    }

    @Test("A sink with nothing to ask for reports no problem")
    func prepareSucceedsWhenThereIsNothingToAsk() async throws {
        try await TestWorkspace.with { _ in
            let sink = FakeReminderSink()
            let sync = RemindersSync(sink: sink)
            #expect(await sync.prepare() == nil)
            #expect(sink.prepareCount == 1)
        }
    }

    // MARK: - What the user is told

    @Test("A failed sync says the todo is still here before it says anything else")
    func failureMessageLeadsWithWhatSurvived() throws {
        let failed = ReminderSyncOutcome.failed(RemindersPermissions.notPromptedMessage)
        let message = try #require(failed.userMessage)
        #expect(message.hasPrefix("Saved here in Memoir"),
                "a user reading only the first clause must learn their todo survived: \(message)")
        #expect(message.contains(RemindersPermissions.pane))

        #expect(ReminderSyncOutcome.synced(reminderID: "x").userMessage != nil)
        #expect(ReminderSyncOutcome.completed.userMessage != nil)
        // Nothing happened. Saying so every pass trains the user to stop reading the line,
        // which costs the failure case its only channel.
        #expect(ReminderSyncOutcome.unchanged.userMessage == nil)
        for reason in ReminderSkipReason.allCases {
            #expect(ReminderSyncOutcome.skipped(reason).userMessage == nil,
                    "\(reason) is correct behaviour, not news")
        }
    }

    @Test("A permission macOS never asked about costs a sentence, never the todo")
    func silentRefusalKeepsTheTodo() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            let memory = MemoryService(store: store, extractors: [RuleExtractor()])
            let sink = FakeReminderSink()
            sink.failEverything(with: ReminderSyncError.notPrompted(RemindersPermissions.notPromptedMessage))
            let sync = RemindersSync(sink: sink)

            let intent = try #require(memory.previewPush("remind me to send the invoice friday",
                                                          now: TestClock.reference))
            let saved = try await memory.commitPush(intent, now: TestClock.reference)

            let outcome = try await sync.push(
                saved, enabled: RemindersConfig(syncToReminders: true).syncToReminders)

            let message = try #require(outcome.userMessage)
            #expect(message.contains(RemindersPermissions.pane),
                    "the one message the user gets has to name what to open: \(message)")
            #expect(!message.lowercased().contains("you denied"))

            // The whole promise, again, on the path that will actually happen to people.
            let row = try #require(try await store.entity(id: saved.id))
            #expect(row.title == saved.title)
            #expect(row.dueAt == saved.dueAt)
            #expect(row.source == .authored)
            #expect(row.deleted == false)
            #expect(sink.reminderCount == 0)
            assertNoNetwork()
        }
    }
}

#if canImport(EventKit)

import EventKit

/// The one place EventKit's own vocabulary is checked.
///
/// `EventKitSink` itself cannot be tested without a TCC prompt, but the table it consults can:
/// this is the mapping that decides whether a user is told they refused something or told
/// macOS never asked, and getting `.notDetermined` wrong here is what produces the useless
/// message. Reading a status value constructs nothing and prompts for nothing.
@Suite("Reminders sync · EventKit's statuses")
struct RemindersAuthorizationMappingTests {

    @Test("EventKit's statuses map onto the framework-free ones")
    func statusMapping() {
        #expect(EventKitSink.grant(.notDetermined) == .notDetermined)
        #expect(EventKitSink.grant(.denied) == .denied)
        #expect(EventKitSink.grant(.restricted) == .restricted)
        #expect(EventKitSink.grant(.fullAccess) == .granted)
        // Write-only cannot read Memoir's markers back out of the notes field, and reading them
        // back is the whole of idempotence: without it every pass makes a second copy of the
        // same todo. No access is the honest reading of it.
        #expect(EventKitSink.grant(.writeOnly) == .denied)
    }
}

#endif
