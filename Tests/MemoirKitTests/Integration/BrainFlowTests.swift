//
//  BrainFlowTests.swift
//  CF-17: Ask returns an attributed answer.
//  CF-18: The floor always answers.
//
//  ─────────────────────────────────────────────────────────────────────────────
//  What is real here and what is not.
//
//  Real: the `Store` on a real SQLite file, `RuleExtractor`, `MemoryService`,
//  `BrainRouter` and `RulesOnlyBrain`. Every answer in this file that matters is
//  assembled from rows that were genuinely written to disk by the real extraction
//  pipeline, and every citation is checked back against that same file.
//
//  Faked: exactly the three brains that leave this process. They are the on-device
//  model (out-of-process inference), the Anthropic API (network) and `claude` (subprocess).
//  Substituting those is what makes the fallback chain assertable at all; leaving them
//  real would make the suite depend on whether Apple Intelligence happens to be enabled
//  on the machine running it, and would let a test spawn the user's own CLI.
//  ─────────────────────────────────────────────────────────────────────────────
//

import Foundation
import Testing

import MemoirFixtures
@testable import MemoirKit

// MARK: - Harness

/// Everything CF-17 and CF-18 need that `TestSupport` does not already provide.
///
/// Namespaced rather than free functions so it cannot collide with another flow's helpers.
enum BrainFlow {

    // MARK: The seeded day
    //
    // `WorkingDay` lives in `MemoirFixtures` so `memoir-eval-seed` builds the same world from
    // the same code. Re-exported under the old names here, because twenty-odd call sites in
    // this file and `LatencyTests` say `BrainFlow.askedAt` and mean exactly that instant.

    /// 09:00 on the local day that contains `TestClock.reference`. Where the day's work starts.
    static var morning: Date { WorkingDay.morning }

    /// 12:00 on the same local day. Every question in this file is asked at this instant,
    /// and it is injected into `MemoryService` and `RulesOnlyBrain` rather than read.
    static var askedAt: Date { WorkingDay.askedAt }

    /// Local midnight before ``morning``. The lower bound consolidation and "today" both use.
    static var dayStart: Date { WorkingDay.dayStart }

    /// `n` minutes after ``morning``.
    static func afterMorning(_ minutes: Double) -> Date { WorkingDay.afterMorning(minutes) }

    /// A seeded working day: five real captures, four sessions, and whatever the real rule
    /// extractor made of them.
    typealias World = WorkingDay.World

    /// Writes one working day into a real store and runs the real consolidation over it.
    static func seedWorkingDay(into store: Store) async throws -> World {
        try await WorkingDay.seed(into: store)
    }

    // MARK: Routers

    /// A router whose brains are exactly the ones supplied.
    ///
    /// The floor is expected to be the *real* `RulesOnlyBrain` over the *real* store: CF-18
    /// against a fake floor would prove nothing. The router still owns the chain order, the
    /// availability cache and the `allowCloud` veto.
    static func router(
        preferred: BrainKind,
        store: Store,
        config: BrainConfig = TestBrainConfig.localOnly,
        brains: [BrainKind: any Brain]
    ) -> BrainRouter {
        BrainRouter(preferred: preferred, store: store, config: config) { kind in brains[kind] }
    }

    /// The real rules brain, reading the seeded day rather than the day the test runs.
    static func floor(_ store: Store) -> RulesOnlyBrain {
        RulesOnlyBrain(store: store, now: { askedAt })
    }

    // MARK: Call recording

    /// One recorded interaction with a brain.
    struct Call: Equatable, CustomStringConvertible {

        /// What the router asked the brain to do.
        enum Event: Equatable {
            case availability(Bool)
            case answer
            case complete
        }

        let brain: BrainKind
        let event: Event

        var description: String {
            switch event {
            case .availability(let ok): return "available(\(ok)):\(brain.rawValue)"
            case .answer: return "answer:\(brain.rawValue)"
            case .complete: return "complete:\(brain.rawValue)"
            }
        }
    }

    /// An ordered, thread-safe record of every brain the router touched.
    ///
    /// Counters alone answer "which brains ran". Ordering is what proves the *chain*: a router
    /// that asked the floor first and the preferred brain second would satisfy every counter
    /// assertion and still be wrong.
    final class CallLog: @unchecked Sendable {
        private let lock = NSLock()
        private var calls: [Call] = []

        func record(_ call: Call) { lock.withLock { calls.append(call) } }

        /// Every call, oldest first.
        var all: [Call] { lock.withLock { calls } }

        /// Human readable form, e.g. `["available(false):anthropicAPI", "answer:rulesOnly"]`.
        var trace: [String] { all.map(\.description) }

        /// The brains that were actually asked to answer, in order.
        var answered: [BrainKind] { all.filter { $0.event == .answer }.map(\.brain) }
    }

    /// Wraps any brain, records every call against a shared log, then delegates.
    ///
    /// Wrapping rather than replacing means the underlying brain keeps working: a `StubBrain`
    /// keeps its counters, and the real `RulesOnlyBrain` still produces a real answer.
    final class Recorder: Brain, @unchecked Sendable {
        let kind: BrainKind
        private let inner: any Brain
        private let log: CallLog

        init(_ inner: any Brain, log: CallLog) {
            self.kind = inner.kind
            self.inner = inner
            self.log = log
        }

        func isAvailable() async -> Bool {
            let value = await inner.isAvailable()
            log.record(Call(brain: kind, event: .availability(value)))
            return value
        }

        func answer(question: String, context: ContextPacket) async throws -> BrainAnswer {
            // Recorded before delegating, so a brain that reports itself available and then
            // throws still leaves a trace of having been tried.
            log.record(Call(brain: kind, event: .answer))
            return try await inner.answer(question: question, context: context)
        }

        func complete(prompt: String, maxTokens: Int) async throws -> String {
            log.record(Call(brain: kind, event: .complete))
            return try await inner.complete(prompt: prompt, maxTokens: maxTokens)
        }
    }

    // MARK: Assertions

    /// Fails unless every cited capture id is a row that actually exists in the store.
    ///
    /// This is the hard half of CF-17. A citation that does not resolve is a fabricated
    /// source: the UI would offer the user a "seen in" link to a capture that was never
    /// recorded, which is strictly worse than citing nothing.
    static func assertCitationsResolve(
        _ answer: BrainAnswer,
        in store: Store,
        expectNonEmpty: Bool = true,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        if expectNonEmpty {
            #expect(
                !answer.citedCaptureIDs.isEmpty,
                "the answer cited nothing, so it cannot be attributed to anything",
                sourceLocation: sourceLocation
            )
        }
        for id in answer.citedCaptureIDs {
            let row = try await store.capture(id: id)
            #expect(
                row != nil,
                "answer cited capture \(id), which is not in the store",
                sourceLocation: sourceLocation
            )
        }
    }

    /// Every sentence `RulesOnlyBrain` produces when it has nothing to say.
    ///
    /// Over a seeded memory, an answer containing any of these has failed CF-18: the promise
    /// is a useful answer, not an apology.
    static let placeholderPhrases = [
        "I have not recorded anything about that yet.",
        "I have not recorded anything yet.",
        "I have not tracked any app time today yet.",
        "Nothing is on your plate that I have picked up on",
        "Nothing in memory about",
        "nothing structured out of them yet",
        "I do not have anything useful on that yet.",
    ]

    /// Fails unless the answer has real substance once its attribution footer is removed.
    static func assertUseful(
        _ answer: BrainAnswer,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let body = answer.text
            .replacingOccurrences(of: RulesOnlyBrain.footer, with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        #expect(!body.isEmpty, "the answer was nothing but its footer", sourceLocation: sourceLocation)
        #expect(
            body.count >= 60,
            "the answer is too thin to be useful: \(body)",
            sourceLocation: sourceLocation
        )
        for phrase in placeholderPhrases {
            #expect(
                !answer.text.contains(phrase),
                "the answer is a placeholder (\"\(phrase)\") over a seeded memory: \(answer.text)",
                sourceLocation: sourceLocation
            )
        }
    }
}

// MARK: - CF-17 · Ask returns an attributed answer

@Suite("CF-17 · Ask returns an attributed answer")
struct AttributedAnswerTests {

    @Test("CF-17 the answer names the brain that actually ran, not the one that was preferred")
    func brainKindMatchesTheBrainThatRan() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            let world = try await BrainFlow.seedWorkingDay(into: store)
            let question = "what do I owe anyone?"
            let packet = try await world.memory.context(for: question, budget: 3_000, now: BrainFlow.askedAt)
            try #require(!packet.captureIDs.isEmpty, "the context packet cited no captures")

            let log = BrainFlow.CallLog()
            let onDevice = StubBrain(kind: .appleOnDevice, answerText: "The migration notes are still open.")
            let floor = BrainFlow.floor(store)
            let router = BrainFlow.router(
                preferred: .appleOnDevice,
                store: store,
                brains: [
                    .appleOnDevice: BrainFlow.Recorder(onDevice, log: log),
                    .rulesOnly: BrainFlow.Recorder(floor, log: log),
                ]
            )

            let answer = try await router.answer(question: question, context: packet)

            #expect(!answer.text.isEmpty)
            // The counter is the proof: exactly one brain executed, and it is the one named.
            #expect(onDevice.answerCallCount == 1)
            #expect(answer.brain == .appleOnDevice)
            #expect(log.answered == [.appleOnDevice], "unexpected brains ran: \(log.trace)")

            try await BrainFlow.assertCitationsResolve(answer, in: store)
            assertNoNetwork()
        }
    }

    @Test("CF-17 the reported brain follows the fallback, it does not follow the preference")
    func brainKindFollowsTheFallback() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            let world = try await BrainFlow.seedWorkingDay(into: store)
            let question = "what do I owe anyone?"
            let packet = try await world.memory.context(for: question, budget: 3_000, now: BrainFlow.askedAt)

            let log = BrainFlow.CallLog()
            let onDevice = StubBrain(kind: .appleOnDevice, available: false, answerText: "must never be seen")
            let router = BrainFlow.router(
                preferred: .appleOnDevice,
                store: store,
                brains: [
                    .appleOnDevice: BrainFlow.Recorder(onDevice, log: log),
                    .rulesOnly: BrainFlow.Recorder(BrainFlow.floor(store), log: log),
                ]
            )

            let answer = try await router.answer(question: question, context: packet)

            // Preferred was `.appleOnDevice`; the answer must not claim to be from it.
            #expect(onDevice.answerCallCount == 0)
            #expect(answer.brain == .rulesOnly)
            #expect(!answer.text.contains("must never be seen"))
            #expect(log.answered == [.rulesOnly], "unexpected brains ran: \(log.trace)")

            try await BrainFlow.assertCitationsResolve(answer, in: store)
            assertNoNetwork()
        }
    }

    @Test("CF-17 every cited capture id resolves to a real row")
    func citationsResolveToRealRows() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            let world = try await BrainFlow.seedWorkingDay(into: store)

            // A lookup question, so the rules brain builds its citations from its own
            // full-text search rather than echoing the packet it was handed.
            let question = "what do you know about Priya Raman"
            let packet = try await world.memory.context(for: question, budget: 3_000, now: BrainFlow.askedAt)
            let router = BrainFlow.router(
                preferred: .rulesOnly,
                store: store,
                brains: [.rulesOnly: BrainFlow.floor(store)]
            )

            let answer = try await router.answer(question: question, context: packet)

            #expect(answer.brain == .rulesOnly)
            try await BrainFlow.assertCitationsResolve(answer, in: store)

            // And the citations are the captures the answer is genuinely made of: every one
            // of them is a row whose text really does mention the subject.
            let seeded = Set(world.captures.map(\.id))
            for id in answer.citedCaptureIDs {
                #expect(seeded.contains(id), "cited capture \(id) was never seeded")
            }
            let firstCited = try #require(answer.citedCaptureIDs.first)
            let cited = try await store.capture(id: firstCited)
            #expect(cited?.text.localizedCaseInsensitiveContains("Priya") == true)
            assertNoNetwork()
        }
    }

    @Test("CF-17 an empty memory cites nothing rather than citing something that does not exist")
    func emptyMemoryCitesNothing() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            let memory = MemoryService(store: store, extractors: [RuleExtractor()])
            let question = "what do you know about Priya Raman"
            let packet = try await memory.context(for: question, budget: 3_000, now: BrainFlow.askedAt)
            #expect(packet.captureIDs.isEmpty)

            let router = BrainFlow.router(
                preferred: .rulesOnly,
                store: store,
                brains: [.rulesOnly: BrainFlow.floor(store)]
            )
            let answer = try await router.answer(question: question, context: packet)

            #expect(!answer.text.isEmpty, "the product must say something even with no memory")
            #expect(answer.brain == .rulesOnly)
            #expect(answer.citedCaptureIDs.isEmpty)
            // Vacuously true, but it is the assertion that would catch an invented citation.
            try await BrainFlow.assertCitationsResolve(answer, in: store, expectNonEmpty: false)
            assertNoNetwork()
        }
    }

    @Test("CF-17 the answer carries the context packet's citations through unchanged")
    func packetCitationsSurviveTheRouter() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            let world = try await BrainFlow.seedWorkingDay(into: store)
            let question = "what happened this morning?"
            let packet = try await world.memory.context(for: question, budget: 3_000, now: BrainFlow.askedAt)
            try #require(!packet.captureIDs.isEmpty)

            let onDevice = StubBrain(kind: .appleOnDevice, answerText: "A deploy was blocked on the rate limiter.")
            let router = BrainFlow.router(
                preferred: .appleOnDevice,
                store: store,
                brains: [.appleOnDevice: onDevice, .rulesOnly: BrainFlow.floor(store)]
            )

            let answer = try await router.answer(question: question, context: packet)

            #expect(answer.citedCaptureIDs == packet.captureIDs)
            try await BrainFlow.assertCitationsResolve(answer, in: store)
            #expect(onDevice.lastQuestion == question)
            assertNoNetwork()
        }
    }
}

// MARK: - CF-17 · The fallback chain

@Suite("CF-17 · The fallback chain")
struct FallbackChainTests {

    /// Builds the standard three-brain chain: a cloud brain, the on-device brain and the real
    /// floor, each wrapped in a recorder sharing one log.
    private func chain(
        store: Store,
        cloud: any Brain,
        onDevice: any Brain,
        log: BrainFlow.CallLog
    ) -> [BrainKind: any Brain] {
        [
            .anthropicAPI: BrainFlow.Recorder(cloud, log: log),
            .appleOnDevice: BrainFlow.Recorder(onDevice, log: log),
            .rulesOnly: BrainFlow.Recorder(BrainFlow.floor(store), log: log),
        ]
    }

    @Test("CF-17 an unavailable preferred brain hands off to the next one in the chain")
    func preferredUnavailableFallsToNext() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            let world = try await BrainFlow.seedWorkingDay(into: store)
            let question = "what do I owe anyone?"
            let packet = try await world.memory.context(for: question, budget: 3_000, now: BrainFlow.askedAt)

            let log = BrainFlow.CallLog()
            let cloud = StubBrain(kind: .anthropicAPI, available: false)
            let onDevice = StubBrain(kind: .appleOnDevice, available: true, answerText: "Two things are open.")
            let router = BrainFlow.router(
                preferred: .anthropicAPI,
                store: store,
                config: TestBrainConfig.cloudEnabled(),
                brains: chain(store: store, cloud: cloud, onDevice: onDevice, log: log)
            )

            let answer = try await router.answer(question: question, context: packet)

            #expect(answer.brain == .appleOnDevice)
            #expect(cloud.answerCallCount == 0)
            #expect(onDevice.answerCallCount == 1)
            #expect(
                log.trace == [
                    "available(false):anthropicAPI",
                    "available(true):appleOnDevice",
                    "answer:appleOnDevice",
                ],
                "chain ran out of order: \(log.trace)"
            )
            assertNoNetwork()
        }
    }

    @Test("CF-17 a brain that reports available and then throws falls through to the floor")
    func availableThenFailingFallsToFloor() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            let world = try await BrainFlow.seedWorkingDay(into: store)
            let question = "what do I owe anyone?"
            let packet = try await world.memory.context(for: question, budget: 3_000, now: BrainFlow.askedAt)

            let log = BrainFlow.CallLog()
            // Reports itself usable, then fails at the last moment. This is the shape a naive
            // router gets wrong: it checks availability, then propagates the throw.
            let cloud = FailingBrain(kind: .anthropicAPI, available: true)
            let onDevice = StubBrain(kind: .appleOnDevice, available: false)
            let router = BrainFlow.router(
                preferred: .anthropicAPI,
                store: store,
                config: TestBrainConfig.cloudEnabled(),
                brains: chain(store: store, cloud: cloud, onDevice: onDevice, log: log)
            )

            let answer = try await router.answer(question: question, context: packet)

            #expect(answer.brain == .rulesOnly)
            #expect(cloud.callCount == 1, "the failing brain was not actually tried")
            #expect(onDevice.answerCallCount == 0)
            #expect(
                log.trace == [
                    "available(true):anthropicAPI",
                    "answer:anthropicAPI",
                    "available(false):appleOnDevice",
                    "available(true):rulesOnly",
                    "answer:rulesOnly",
                ],
                "chain ran out of order: \(log.trace)"
            )
            // The floor did not just fire, it produced the real answer.
            BrainFlow.assertUseful(answer)
            try await BrainFlow.assertCitationsResolve(answer, in: store)
            assertNoNetwork()
        }
    }

    @Test("CF-17 preferred then on-device then rulesOnly, in that order")
    func fullChainEndsAtTheFloor() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            let world = try await BrainFlow.seedWorkingDay(into: store)
            let question = "what do I owe anyone?"
            let packet = try await world.memory.context(for: question, budget: 3_000, now: BrainFlow.askedAt)

            let log = BrainFlow.CallLog()
            let cloud = StubBrain(kind: .anthropicAPI, available: false)
            let onDevice = StubBrain(kind: .appleOnDevice, available: false)
            let router = BrainFlow.router(
                preferred: .anthropicAPI,
                store: store,
                config: TestBrainConfig.cloudEnabled(),
                brains: chain(store: store, cloud: cloud, onDevice: onDevice, log: log)
            )

            let answer = try await router.answer(question: question, context: packet)

            #expect(answer.brain == .rulesOnly)
            #expect(log.answered == [.rulesOnly])
            #expect(
                log.trace == [
                    "available(false):anthropicAPI",
                    "available(false):appleOnDevice",
                    "available(true):rulesOnly",
                    "answer:rulesOnly",
                ],
                "chain ran out of order: \(log.trace)"
            )
            #expect(cloud.availabilityCallCount == 1)
            #expect(onDevice.availabilityCallCount == 1)
            BrainFlow.assertUseful(answer)
            assertNoNetwork()
        }
    }

    @Test("CF-17 the chain is walked once per question, not once per brain probe")
    func availabilityIsProbedOncePerBrain() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            let world = try await BrainFlow.seedWorkingDay(into: store)
            let packet = try await world.memory.context(for: "what is open?", budget: 3_000, now: BrainFlow.askedAt)

            let log = BrainFlow.CallLog()
            let onDevice = StubBrain(kind: .appleOnDevice, available: true, answerText: "One thing is open.")
            let router = BrainFlow.router(
                preferred: .appleOnDevice,
                store: store,
                brains: [
                    .appleOnDevice: BrainFlow.Recorder(onDevice, log: log),
                    .rulesOnly: BrainFlow.Recorder(BrainFlow.floor(store), log: log),
                ]
            )

            _ = try await router.answer(question: "what is open?", context: packet)
            _ = try await router.answer(question: "what is open?", context: packet)

            // Two answers, but the availability probe is cached for 30s, so it runs once.
            #expect(onDevice.answerCallCount == 2)
            #expect(onDevice.availabilityCallCount == 1, "availability probe is not being cached")
            #expect(log.answered == [.appleOnDevice, .appleOnDevice])
            assertNoNetwork()
        }
    }
}

// MARK: - CF-18 · The floor always answers

@Suite("CF-18 · The floor always answers")
struct FloorAnswersTests {

    @Test("CF-83 the floor never claims a model is not running")
    func floorDoesNotAssertModelState() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            _ = try await BrainFlow.seedWorkingDay(into: store)

            let floor = RulesOnlyBrain(store: store, now: { BrainFlow.askedAt })
            let answer = try await floor.answer(question: "what do I owe anyone", context: .empty)

            // The floor is a template over SQLite. It is reached in two very different
            // situations (no model installed at all, and a model that ran and whose reply
            // was rejected or bettered), and it cannot tell them apart. Asserting the first
            // told a user with a configured, available, just-attempted model that no model
            // was running, and they reasonably concluded the product was broken.
            #expect(!answer.text.localizedCaseInsensitiveContains("no model is running"),
                    "the floor asserted something it cannot know:\n\(answer.text)")

            // It must still say where the answer came from: that is the honest half.
            #expect(answer.text.localizedCaseInsensitiveContains("your records")
                    || answer.text.localizedCaseInsensitiveContains("this mac"),
                    "the floor must still attribute itself:\n\(answer.text)")
        }
    }


    /// A router with every brain but `rulesOnly` switched off, exactly as CF-18 specifies.
    private func floorOnly(store: Store, log: BrainFlow.CallLog) -> BrainRouter {
        BrainFlow.router(
            preferred: .appleOnDevice,
            store: store,
            config: TestBrainConfig.localOnly,
            brains: [
                .appleOnDevice: BrainFlow.Recorder(StubBrain(kind: .appleOnDevice, available: false), log: log),
                .anthropicAPI: BrainFlow.Recorder(StubBrain(kind: .anthropicAPI, available: false), log: log),
                .claudeCode: BrainFlow.Recorder(StubBrain(kind: .claudeCode, available: false), log: log),
                .rulesOnly: BrainFlow.Recorder(BrainFlow.floor(store), log: log),
            ]
        )
    }

    @Test(
        "CF-18 a realistic question still gets a useful, non-placeholder answer",
        arguments: [
            "what am I working on?",
            "what do I owe anyone?",
            "where did my time go today?",
        ]
    )
    func everyQuestionIsAnswered(question: String) async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            let world = try await BrainFlow.seedWorkingDay(into: store)
            let packet = try await world.memory.context(for: question, budget: 3_000, now: BrainFlow.askedAt)

            let log = BrainFlow.CallLog()
            let router = floorOnly(store: store, log: log)
            #expect(await router.current() == .rulesOnly)

            let answer = try await router.answer(question: question, context: packet)

            #expect(answer.brain == .rulesOnly)
            #expect(log.answered == [.rulesOnly], "something other than the floor answered: \(log.trace)")
            BrainFlow.assertUseful(answer)
            // The attribution footer is part of the promise: the user always knows no model ran.
            #expect(answer.text.hasSuffix(RulesOnlyBrain.footer))
            try await BrainFlow.assertCitationsResolve(answer, in: store, expectNonEmpty: false)
            assertNoNetwork()
        }
    }

    @Test("CF-18 \"what am I working on\" names the apps and windows that were really on screen")
    func workingOnNamesRealActivity() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            let world = try await BrainFlow.seedWorkingDay(into: store)
            let question = "what am I working on?"
            let packet = try await world.memory.context(for: question, budget: 3_000, now: BrainFlow.askedAt)

            let log = BrainFlow.CallLog()
            let answer = try await floorOnly(store: store, log: log)
                .answer(question: question, context: packet)

            // Time really tracked, from the real session rows.
            #expect(answer.text.contains("tracked today across 3 apps"))
            for line in ["- Google Chrome: 50 min", "- Slack: 45 min", "- Mail: 25 min"] {
                #expect(answer.text.contains(line), "missing \"\(line)\" in:\n\(answer.text)")
            }
            #expect(answer.text.contains("Away from the keyboard"))

            // Window titles really captured.
            let titles = world.captures.compactMap(\.windowTitle)
            try #require(!titles.isEmpty)
            let named = titles.filter { answer.text.contains($0) }
            #expect(!named.isEmpty, "no seeded window title appears in:\n\(answer.text)")

            // Entities the real extractor really produced today.
            #expect(answer.text.contains("Picked up today:"))
            BrainFlow.assertUseful(answer)
            assertNoNetwork()
        }
    }

    @Test("CF-18 \"what do I owe anyone\" lists the commitments that are really in memory")
    func owedNamesRealCommitments() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            let world = try await BrainFlow.seedWorkingDay(into: store)
            let question = "what do I owe anyone?"
            let packet = try await world.memory.context(for: question, budget: 3_000, now: BrainFlow.askedAt)

            let log = BrainFlow.CallLog()
            let answer = try await floorOnly(store: store, log: log)
                .answer(question: question, context: packet)

            // What the product will ASSERT, which is not everything it holds. A commitment
            // read off a browser tab is kept and marked provisional — see CF-79, which was
            // reversed on measured grounds: every tab is a reading surface now, including the
            // ones people write in. Comparing the header against every stored row would be
            // comparing it against rows the surface is deliberately refusing to claim.
            let commitments = try await store.entities(kind: .commitment, includeDeleted: false)
                .filter { !$0.provisional }
            try #require(!commitments.isEmpty, "the seeded day produced no assertable commitments")

            // The header states the true number held in memory.
            #expect(answer.text.contains("\(commitments.count) open"))

            // Dated commitments sort to the front of the list, so all of them are rendered.
            let dated = commitments.filter { $0.dueAt != nil }
            try #require(dated.count >= 3, "the seeded day should yield several dated commitments")
            try #require(dated.count <= 12, "more dated commitments than the template renders")
            for commitment in dated {
                #expect(
                    answer.text.contains(commitment.title),
                    "commitment \"\(commitment.title)\" is in memory but not in:\n\(answer.text)"
                )
            }

            // Every rendered commitment carries a due phrase rather than a bare title.
            #expect(answer.text.contains("due ") || answer.text.contains("overdue"))

            // Commitment titles are lifted verbatim from the screen and usually already end a
            // sentence, so the template must not punctuate them twice.
            for doubled in ["..", "?.", "!.", "\u{2026}."] {
                #expect(
                    !answer.text.contains(doubled),
                    "doubled punctuation \"\(doubled)\" in:\n\(answer.text)"
                )
            }
            BrainFlow.assertUseful(answer)
            assertNoNetwork()
        }
    }

    @Test("CF-18 \"where did my time go\" reports the real session breakdown")
    func timeGoneReportsRealSessions() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            let world = try await BrainFlow.seedWorkingDay(into: store)
            let question = "where did my time go today?"
            let packet = try await world.memory.context(for: question, budget: 3_000, now: BrainFlow.askedAt)

            let log = BrainFlow.CallLog()
            let answer = try await floorOnly(store: store, log: log)
                .answer(question: question, context: packet)

            // 45 + 25 + 50 active minutes across three apps; the idle stretch is excluded
            // from the total and reported separately.
            #expect(answer.text.contains("2h tracked today across 3 apps"))
            let active = world.sessions.filter { !$0.idle }
            for session in active {
                #expect(
                    answer.text.contains("- \(session.appName): "),
                    "no line for \(session.appName) in:\n\(answer.text)"
                )
            }
            BrainFlow.assertUseful(answer)
            assertNoNetwork()
        }
    }

    @Test("CF-18 a question the templates do not recognise still gets a real brief")
    func unrecognisedQuestionGetsABrief() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            let world = try await BrainFlow.seedWorkingDay(into: store)
            let question = "give me the rate limiter situation"
            let packet = try await world.memory.context(for: question, budget: 3_000, now: BrainFlow.askedAt)

            let log = BrainFlow.CallLog()
            let answer = try await floorOnly(store: store, log: log)
                .answer(question: question, context: packet)

            #expect(answer.brain == .rulesOnly)
            BrainFlow.assertUseful(answer)
            // The brief always names what is actually in play.
            #expect(answer.text.contains("Recently in play:") || answer.text.contains("Closest things I have"))
            assertNoNetwork()
        }
    }

    @Test("CF-18 the real router with nothing faked still answers from memory")
    func realRouterAnswers() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            let world = try await BrainFlow.seedWorkingDay(into: store)
            let question = "what do I owe anyone?"
            let packet = try await world.memory.context(for: question, budget: 3_000, now: BrainFlow.askedAt)

            // No factory, no stubs: the production initialiser, the production chain.
            // `rulesOnly` is preferred and always available, so no model, subprocess or
            // network is ever reached, and nothing here depends on the machine's setup.
            let router = BrainRouter(preferred: .rulesOnly, store: store, config: TestBrainConfig.localOnly)
            #expect(await router.current() == .rulesOnly)

            let answer = try await router.answer(question: question, context: packet)

            #expect(answer.brain == .rulesOnly)
            #expect(!answer.text.isEmpty)
            #expect(answer.text.contains(" open"))

            // Wall-clock independent: dated commitments sort first whatever "now" is, so the
            // titles are always rendered even though this brain is reading the real clock.
            // Non-provisional only, for the same reason as above: the surface renders what it
            // is prepared to claim, and a promise read off a browser tab is not that.
            let commitments = try await store.entities(kind: .commitment, includeDeleted: false)
                .filter { !$0.provisional }
            let dated = commitments.filter { $0.dueAt != nil }
            try #require(!dated.isEmpty)
            for commitment in dated.prefix(3) {
                #expect(answer.text.contains(commitment.title))
            }
            for phrase in BrainFlow.placeholderPhrases {
                #expect(!answer.text.contains(phrase), "the real router produced a placeholder: \(answer.text)")
            }
            assertNoNetwork()
        }
    }

    @Test("CF-18 the floor answers even when the memory is empty")
    func floorAnswersEmptyMemory() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            let log = BrainFlow.CallLog()
            let router = floorOnly(store: store, log: log)

            for question in ["what am I working on?", "what do I owe anyone?", "where did my time go today?"] {
                let answer = try await router.answer(question: question, context: .empty)
                #expect(answer.brain == .rulesOnly)
                // Honest, not silent: an empty memory is allowed to say so, but it must say
                // something, and it must still declare which brain produced it.
                #expect(!answer.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                #expect(answer.text.hasSuffix(RulesOnlyBrain.footer))
                #expect(answer.citedCaptureIDs.isEmpty)
            }
            #expect(log.answered == [.rulesOnly, .rulesOnly, .rulesOnly])
            assertNoNetwork()
        }
    }

    @Test("CF-18 the floor may decline rather than recite a status report")
    func floorDeclinesWhenItHasNothingSpecific() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            let world = try await BrainFlow.seedWorkingDay(into: store)
            let floor = BrainFlow.floor(store)

            // The day is fully seeded, so the general brief has plenty to recite, which is
            // exactly the trap. Offered as a fallback for a question about 1995 it would
            // read "N open commitments. Recently in play: …", implying a record that cannot
            // exist. Worse than a refusal, because it sounds like an answer.
            let unanswerable = "what was I doing in 1995"
            let packet = try await world.memory.context(
                for: unanswerable, budget: 3_000, now: BrainFlow.askedAt)
            #expect(await floor.answerIfSpecific(question: unanswerable, context: packet) == nil)

            // It still answers what it genuinely knows.
            let real = "what do I owe anyone"
            let realPacket = try await world.memory.context(
                for: real, budget: 3_000, now: BrainFlow.askedAt)
            let answered = await floor.answerIfSpecific(question: real, context: realPacket)
            #expect(answered != nil)

            // `answer` itself is unchanged. The floor ALWAYS produces something: that is
            // what makes it the floor, and CF-18 depends on it. Only the fallback path,
            // where a refusal is the honest alternative, is allowed to decline.
            let always = try await floor.answer(question: unanswerable, context: packet)
            #expect(!always.text.isEmpty)
        }
    }

    @Test("CF-17b the floor refuses an out-of-scope question instead of rendering a template")
    func floorHonoursTheRoutedScope() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            let world = try await BrainFlow.seedWorkingDay(into: store)
            let floor = BrainFlow.floor(store)

            // A seeded day is again the trap. The floor's own classifier has no notion of
            // scope: every question is matched against the four shapes it can render, and
            // the nearest one wins. Asked what they had for lunch the user got today's app
            // table: nothing false in it, and an answer to a question nobody asked.
            for question in ["what did I have for lunch", "how much money did I spend today"] {
                let packet = try await world.memory.context(
                    for: question, budget: 3_000, now: BrainFlow.askedAt, category: .outOfScope)
                // A refusal is a SPECIFIC answer, so the fallback path keeps it rather than
                // declining and letting a generated one stand.
                let answer = await floor.answerIfSpecific(
                    question: question, context: packet, category: .outOfScope)
                let text = try #require(answer?.text, "the floor declined instead of refusing")
                #expect(text.contains("no record"), "got: \(text)")
                #expect(!text.contains("app time"), "the floor rendered a template: \(text)")
            }
        }
    }

    @Test("CF-18 a fragment inside a longer word is not a match")
    func matcherRequiresWholeWords() {
        let repo = Entity(kind: .project, title: "cadenroe/last30days-skill",
                          detail: nil, dueAt: nil, confidence: 0.8)
        let real = Entity(kind: .project, title: "Lumenfield image generator",
                          detail: nil, dueAt: nil, confidence: 0.8)

        // The real regression: "last" in the question matched the fragment inside
        // "last30days-skill", and the floor offered that repo as "the closest thing I have
        // to that". A confident coincidence is the worst thing a memory can produce.
        let question = "what was I checking on lmuendeild last"
        #expect(RulesOnlyBrain.matches(question: question, in: [repo, real]).isEmpty)

        // A genuine whole-word match still works.
        #expect(RulesOnlyBrain.matches(question: "what was the lumenfield page",
                                       in: [repo, real]).map(\.title) == [real.title])
        // And a real reference to that repo still finds it.
        #expect(RulesOnlyBrain.matches(question: "what was that cadenroe repo",
                                       in: [repo, real]).map(\.title) == [repo.title])

        // An observational verb is not a subject. "look" says how the thing was come across,
        // never what it was, and a commitment that happens to contain "take a look" is not an
        // answer to a question about a repo. "looking" was already stopped and "look" was not,
        // which is a distinction nobody meant to draw.
        let chore = Entity(kind: .commitment,
                           title: "The import is still failing. Can you take a look before the demo?",
                           detail: nil, dueAt: nil, confidence: 0.9)
        #expect(RulesOnlyBrain.matches(question: "what repo did I look at about screen memory",
                                       in: [chore, repo, real]).isEmpty)
        #expect(RulesOnlyBrain.matches(question: "find the github page I was reading",
                                       in: [chore, repo, real]).isEmpty)
    }

    @Test("CF-18 the router's reference date reaches the floor, not just retrieval")
    func routerClockReachesTheFloor() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            let world = try await BrainFlow.seedWorkingDay(into: store)
            let question = "how much time did I spend in chrome today"

            // The PRODUCTION constructor, with no brain factory, so the floor under test is
            // the one `BrainRouter` builds for itself. That is the whole point: six sites in
            // that file made a `RulesOnlyBrain` with the wall clock while retrieval was
            // already being handed a reference date, and the two disagreed silently.
            let packet = try await world.memory.context(
                for: question, budget: 3_000, now: BrainFlow.askedAt, category: .accounting)
            let dated = BrainRouter(
                preferred: .rulesOnly, store: store, config: TestBrainConfig.localOnly,
                now: { BrainFlow.askedAt })
            let answer = try await dated.answer(
                question: question, context: packet, category: .accounting)

            // Chrome ran 50 minutes on the seeded day. A router that rendered "today" from
            // the wall clock has no seeded day at all and reports nothing tracked.
            #expect(answer.text.contains("Google Chrome: 50 min"), "got: \(answer.text)")

            // The negative control, and the reason this test is worth its runtime: the SAME
            // store, the SAME packet, the default clock. If this ever starts finding the
            // seeded day, the machine's own date has wandered into March 2026 and the
            // assertion above has stopped proving anything.
            let undated = BrainRouter(
                preferred: .rulesOnly, store: store, config: TestBrainConfig.localOnly)
            let drifted = try await undated.answer(
                question: question, context: packet, category: .accounting)
            #expect(!drifted.text.contains("Google Chrome: 50 min"), "got: \(drifted.text)")

            assertNoNetwork()
        }
    }
}
