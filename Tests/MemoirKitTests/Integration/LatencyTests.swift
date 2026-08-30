//
//  LatencyTests.swift
//  CF-17c: the user gets a grounded answer at once, and the guarded one when it lands.
//
//  ─────────────────────────────────────────────────────────────────────────────
//  Why this suite exists, and why it contains no timings.
//
//  MEASURED on the real database (482 vectors), "what was that repo about screen
//  memory": 24s end to end, of which 4.2s builds the context and ~20s is the
//  on-device model. Almost all of that 20s is prefill of the context packet, not
//  cold start. Same rig, same warm model, prompt size varied:
//
//      empty context (   85 chars)   time to first token  1 582ms
//      5 lines       ( 1 184 chars)                       7 367ms
//      20 lines      ( 4 482 chars)                      11 606ms
//      40 lines      ( 8 880 chars)                      17 252ms
//
//  Prefill cannot be warmed away, because the context is different every time. So
//  `answerProgressively` covers it instead: the grounded `rulesOnly` answer goes to
//  the caller while the model is still working.
//
//  Every assertion below is about ORDERING and CORRECTNESS. None is about elapsed
//  time. A test that asserts "the floor arrived in under 2s" fails on a loaded CI
//  box and passes on a broken implementation that happens to run on a fast one; it
//  measures the machine, not the code. The timings belong in the commit message.
//
//  What is real here: the `Store` on a real SQLite file, the real extraction
//  pipeline, the real `MemoryService`, the real `BrainRouter` with its full guard
//  stack, and the real `RulesOnlyBrain` underneath the floor. Faked: only the
//  generative brain, because it is the thing that leaves the process.
//  ─────────────────────────────────────────────────────────────────────────────
//

import Foundation
import Testing

@testable import MemoirKit

// MARK: - Harness

/// Helpers this suite needs on top of `TestSupport` and `BrainFlow`.
enum Latency {

    /// The question every test here asks.
    ///
    /// A LOOKUP, deliberately. `RulesOnlyBrain.renderLookup` answers out of full-text search
    /// with no date arithmetic anywhere in it, so the floor's answer does not depend on the
    /// day the suite runs, which matters because `BrainRouter` builds its floor with the
    /// brain's default clock, exactly as `rejected` already does. A "what did I do today"
    /// question would be answered against the real today and find nothing in a memory seeded
    /// in March 2026, so the floor would go quiet and these tests would prove nothing.
    static let lookup = "what do you know about Priya Raman"

    /// An ordered, thread-safe record of what happened in which order.
    ///
    /// The whole point of this suite is sequence, so the assertion is a sequence.
    final class Order: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [String] = []

        func record(_ event: String) { lock.withLock { events.append(event) } }
        var all: [String] { lock.withLock { events } }
    }

    /// A place for the floor callback to leave what it was given. `onFloor` is `@Sendable`,
    /// so a plain captured `var` will not do.
    final class Caught: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: BrainAnswer?

        func hold(_ answer: BrainAnswer) { lock.withLock { stored = answer } }
        var value: BrainAnswer? { lock.withLock { stored } }
        var fired: Bool { value != nil }
    }

    /// A latch that can be opened once and awaited any number of times.
    ///
    /// Used to hold a fake brain still until the floor has been delivered. Opening it twice
    /// is harmless, which is what lets a test open it defensively without racing itself.
    actor Latch {
        private var open = false
        private var waiting: [CheckedContinuation<Void, Never>] = []

        func openUp() {
            guard !open else { return }
            open = true
            let pending = waiting
            waiting.removeAll()
            for continuation in pending { continuation.resume() }
        }

        func wait() async {
            if open { return }
            await withCheckedContinuation { waiting.append($0) }
        }
    }

    /// A brain that will not answer until a latch is opened, then answers what it was told to.
    ///
    /// This is how "the floor arrived while the model was still working" becomes provable
    /// without reading a clock: the latch is opened by the floor callback, so a router that
    /// waited for the model before delivering the floor could never finish at all.
    final class HeldBrain: Brain, @unchecked Sendable {
        let kind: BrainKind
        private let latch: Latch
        private let text: String
        private let order: Order?

        init(kind: BrainKind = .appleOnDevice, latch: Latch, text: String, order: Order? = nil) {
            self.kind = kind
            self.latch = latch
            self.text = text
            self.order = order
        }

        func isAvailable() async -> Bool { true }

        func answer(question: String, context: ContextPacket) async throws -> BrainAnswer {
            await latch.wait()
            order?.record("model")
            return BrainAnswer(text: text, brain: kind, citedCaptureIDs: context.captureIDs, latency: 0)
        }

        func complete(prompt: String, maxTokens: Int) async throws -> String { text }
    }

    /// A brain that reports itself available and then fails. Stands in for a model that dies
    /// mid-answer, which `StubBrain` cannot express.
    struct FailingBrain: Brain {
        let kind: BrainKind

        func isAvailable() async -> Bool { true }

        func answer(question: String, context: ContextPacket) async throws -> BrainAnswer {
            throw MemoirError.brainUnavailable(kind, "the model went away")
        }

        func complete(prompt: String, maxTokens: Int) async throws -> String {
            throw MemoirError.brainUnavailable(kind, "the model went away")
        }
    }

    /// The seeded working day plus the context packet for ``lookup``.
    static func world(_ store: Store) async throws -> (BrainFlow.World, ContextPacket) {
        let world = try await BrainFlow.seedWorkingDay(into: store)
        let packet = try await world.memory.context(for: lookup, budget: 3_000, now: BrainFlow.askedAt)
        return (world, packet)
    }
}

// MARK: - CF-17c · The floor lands first

@Suite("CF-17c · a grounded answer arrives before the model's")
struct ProgressiveAnswerTests {

    @Test("CF-17c the floor callback runs before the final answer is returned")
    func floorPrecedesTheFinalAnswer() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            let (_, packet) = try await Latency.world(store)

            let order = Latency.Order()
            let brain = StubBrain(
                kind: .appleOnDevice,
                answerText: "Priya Raman asked for the migration notes in Slack."
            )
            let router = BrainFlow.router(
                preferred: .appleOnDevice,
                store: store,
                brains: [.appleOnDevice: brain, .rulesOnly: BrainFlow.floor(store)]
            )

            let caught = Latency.Caught()
            _ = try await router.answerProgressively(
                question: Latency.lookup, context: packet, category: .recall
            ) { floor in
                order.record("floor")
                caught.hold(floor)
            }
            order.record("final")

            #expect(order.all == ["floor", "final"], "unexpected sequence: \(order.all)")
            let floor = try #require(caught.value, "the floor never fired, so the user watched a spinner")
            // The floor is the grounded brain, not the model's phrasing dressed up as one.
            #expect(floor.brain == .rulesOnly)
            #expect(floor.text.contains("Priya"))
            assertNoNetwork()
        }
    }

    @Test("CF-17c the floor is delivered while the model is still working")
    func floorArrivesBeforeTheModelHasAnswered() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            let (_, packet) = try await Latency.world(store)

            // The latch is opened BY the floor callback. A router that waited on the model
            // before delivering the floor would deadlock rather than pass, which is exactly
            // the discrimination a wall-clock assertion fails to make.
            let latch = Latency.Latch()
            let order = Latency.Order()
            let held = Latency.HeldBrain(
                latch: latch,
                text: "Priya Raman asked for the migration notes in Slack.",
                order: order
            )
            let router = BrainFlow.router(
                preferred: .appleOnDevice,
                store: store,
                brains: [.appleOnDevice: held, .rulesOnly: BrainFlow.floor(store)]
            )

            let final = try await router.answerProgressively(
                question: Latency.lookup, context: packet, category: .recall
            ) { _ in
                order.record("floor")
                Task { await latch.openUp() }
            }
            order.record("final")

            #expect(order.all == ["floor", "model", "final"], "unexpected sequence: \(order.all)")
            #expect(final.brain == .appleOnDevice)
            #expect(final.text.contains("Priya Raman"))
            assertNoNetwork()
        }
    }

    @Test("CF-17c the model's phrasing is what the caller is finally given")
    func finalAnswerIsTheModelsWhenItIsGood() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            let (_, packet) = try await Latency.world(store)

            let phrasing = "Priya Raman asked you in Slack to drop the migration notes in the channel."
            let brain = StubBrain(kind: .appleOnDevice, answerText: phrasing)
            let router = BrainFlow.router(
                preferred: .appleOnDevice,
                store: store,
                brains: [.appleOnDevice: brain, .rulesOnly: BrainFlow.floor(store)]
            )

            let caught = Latency.Caught()
            let final = try await router.answerProgressively(
                question: Latency.lookup, context: packet, category: .recall
            ) { caught.hold($0) }

            #expect(final.text == phrasing)
            #expect(final.brain == .appleOnDevice)
            // Two different answers to the same question: the fast one and the good one.
            let floorText = try #require(caught.value?.text)
            #expect(floorText != final.text)
            try await BrainFlow.assertCitationsResolve(final, in: store)
            assertNoNetwork()
        }
    }

    @Test("CF-17c the progressive answer matches the one the plain call would have given")
    func progressiveMatchesPlain() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            let (_, packet) = try await Latency.world(store)

            let phrasing = "Priya Raman asked you in Slack to drop the migration notes in the channel."
            func router() -> BrainRouter {
                BrainFlow.router(
                    preferred: .appleOnDevice,
                    store: store,
                    brains: [
                        .appleOnDevice: StubBrain(kind: .appleOnDevice, answerText: phrasing),
                        .rulesOnly: BrainFlow.floor(store),
                    ]
                )
            }

            let plain = try await router().answer(
                question: Latency.lookup, context: packet, category: .recall)
            let progressive = try await router().answerProgressively(
                question: Latency.lookup, context: packet, category: .recall) { _ in }

            // Speed is allowed to change what the user SEES FIRST. It is not allowed to
            // change what they end up with.
            #expect(progressive.text == plain.text)
            #expect(progressive.brain == plain.brain)
            #expect(progressive.citedCaptureIDs == plain.citedCaptureIDs)
            assertNoNetwork()
        }
    }
}

// MARK: - CF-17c · The guards are not a fast path

@Suite("CF-17c · answering twice does not relax a single guard")
struct ProgressiveGuardTests {

    @Test("CF-17c an invented figure is still rejected on the progressive path")
    func inventedFigureIsStillRejected() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            let (_, packet) = try await Latency.world(store)

            // CF-17b, verbatim: the memory has no such figure and the question did not
            // supply one, so the answer is fabricated and must not reach the user.
            let invention = "Priya Raman is owed $4,750 for the migration work."
            try #require(!packet.summary.contains("4,750") && !packet.summary.contains("4750"),
                         "the fixture accidentally contains the figure, so this proves nothing")

            let brain = StubBrain(kind: .appleOnDevice, answerText: invention)
            let router = BrainFlow.router(
                preferred: .appleOnDevice,
                store: store,
                brains: [.appleOnDevice: brain, .rulesOnly: BrainFlow.floor(store)]
            )

            let caught = Latency.Caught()
            let final = try await router.answerProgressively(
                question: Latency.lookup, context: packet, category: .recall
            ) { caught.hold($0) }

            #expect(final.text != invention)
            #expect(!final.text.contains("4,750"))
            #expect(!final.text.contains("4750"))
            // The user was not left with nothing while the invention was thrown away: the
            // guard rejecting an answer is not a reason to take back a grounded one.
            #expect(caught.fired)
            assertNoNetwork()
        }
    }

    @Test("CF-17c an invented host is still rejected on the progressive path")
    func inventedHostIsStillRejected() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            let (_, packet) = try await Latency.world(store)

            let invention = "Priya Raman posted it on https://praman-migrations.example.dev"
            try #require(!packet.summary.contains("praman-migrations"))

            let router = BrainFlow.router(
                preferred: .appleOnDevice,
                store: store,
                brains: [
                    .appleOnDevice: StubBrain(kind: .appleOnDevice, answerText: invention),
                    .rulesOnly: BrainFlow.floor(store),
                ]
            )

            let final = try await router.answerProgressively(
                question: Latency.lookup, context: packet, category: .recall) { _ in }

            #expect(!final.text.contains("praman-migrations"))
            assertNoNetwork()
        }
    }

    @Test("CF-17c an invented action is still rejected on the progressive path")
    func inventedActionIsStillRejected() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            let (_, packet) = try await Latency.world(store)

            // The context records what was ON SCREEN. "You sent" is a claim about the user.
            let invention = "You sent Priya Raman the migration notes."
            let router = BrainFlow.router(
                preferred: .appleOnDevice,
                store: store,
                brains: [
                    .appleOnDevice: StubBrain(kind: .appleOnDevice, answerText: invention),
                    .rulesOnly: BrainFlow.floor(store),
                ]
            )

            let final = try await router.answerProgressively(
                question: Latency.lookup, context: packet, category: .recall) { _ in }

            #expect(final.text != invention)
            assertNoNetwork()
        }
    }

    @Test("CF-17c a resumption question gets the brief as its floor, other questions do not")
    func onlyResumptionGetsTheGeneralBrief() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            let world = try await BrainFlow.seedWorkingDay(into: store)

            // A question that matches no entity title, so `answerIfSpecific` declines it and
            // only the `resumption` exception can produce a floor. Asserted rather than
            // assumed: "where did I leave off" looks like the obvious choice and is not one,
            // because "off" is a whole word in the seeded "keep the flag default off".
            let question = "where was I"
            #expect(RulesOnlyBrain.matches(question: question, in: world.entities).isEmpty,
                    "the fixture now matches this question, so it no longer produces the brief")
            let packet = try await world.memory.context(
                for: question, budget: 3_000, now: BrainFlow.askedAt)

            let latch = Latency.Latch()
            func router() -> BrainRouter {
                BrainFlow.router(
                    preferred: .appleOnDevice,
                    store: store,
                    brains: [
                        .appleOnDevice: Latency.HeldBrain(latch: latch, text: "You had the deploy thread open."),
                        .rulesOnly: BrainFlow.floor(store),
                    ]
                )
            }

            let resumption = Latency.Caught()
            _ = try await router().answerProgressively(
                question: question, context: packet, category: .resumption
            ) { floor in
                resumption.hold(floor)
                Task { await latch.openUp() }
            }
            let brief = try #require(resumption.value, "a resumption question got no floor at all")
            #expect(brief.brain == .rulesOnly)

            // The same question routed as recall gets nothing, because there the brief would
            // be a status report standing in for an answer: the "what was I doing in 1995"
            // failure. The exception is scoped to the one category it is true for.
            let recall = Latency.Caught()
            _ = try await router().answerProgressively(
                question: question, context: packet, category: .recall
            ) { recall.hold($0) }
            #expect(!recall.fired, "the general brief leaked into a recall answer")

            assertNoNetwork()
        }
    }

    @Test("CF-17c a question that never reaches a model gets no floor to flash")
    func deterministicAnswersFireNoFloor() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            _ = try await Latency.world(store)

            let router = BrainFlow.router(
                preferred: .appleOnDevice,
                store: store,
                brains: [
                    .appleOnDevice: StubBrain(kind: .appleOnDevice, answerText: "must never be seen"),
                    .rulesOnly: BrainFlow.floor(store),
                ]
            )

            // Each of these already answers in single-digit milliseconds. Showing a floor
            // first would put a second, different sentence on screen for no reason at all.
            //
            // Small talk is checked separately below: `smallTalkReply` picks at random, so
            // two calls are allowed to differ in wording and comparing them proves nothing.
            let cases: [(String, QuestionCategory?)] = [
                ("how much did I spend today", .outOfScope),
                ("remind me to send the invoice friday", .push),
                // The verbatim phrasing from the incident in `Grounding.credentialRefusal`.
                ("what is my password for github", nil),
            ]

            for (question, category) in cases {
                let order = Latency.Order()
                let progressive = try await router.answerProgressively(
                    question: question, context: .empty, category: category
                ) { _ in order.record("floor") }
                let plain = try await router.answer(
                    question: question, context: .empty, category: category)

                #expect(order.all.isEmpty, "\"\(question)\" flashed a floor answer it did not need")
                #expect(progressive.text == plain.text, "\"\(question)\" answered differently")
                #expect(!progressive.text.contains("must never be seen"),
                        "\"\(question)\" reached a model it should never have reached")
            }

            let order = Latency.Order()
            let greeting = try await router.answerProgressively(
                question: "hey", context: .empty, category: .smallTalk
            ) { _ in order.record("floor") }
            #expect(order.all.isEmpty, "a greeting flashed a floor answer it did not need")
            #expect(greeting.brain == .rulesOnly)
            #expect(!greeting.text.contains("must never be seen"))
            #expect(greeting.text.hasSuffix("?"), "a greeting got something other than a greeting back: \(greeting.text)")

            assertNoNetwork()
        }
    }
}

// MARK: - CF-17c · The floor is what survives a failure

@Suite("CF-17c · a failed model does not take the floor away")
struct ProgressiveFallbackTests {

    @Test("CF-17c when every brain fails the user keeps the floor answer")
    func floorSurvivesTotalFailure() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            let (_, packet) = try await Latency.world(store)

            // Both links of the chain fail, including the one the router would normally end
            // on, so `answer` throws. The floor `answerProgressively` builds is a separate,
            // real `RulesOnlyBrain` over the same store, so it still has something to say.
            let router = BrainFlow.router(
                preferred: .appleOnDevice,
                store: store,
                brains: [
                    .appleOnDevice: Latency.FailingBrain(kind: .appleOnDevice),
                    .rulesOnly: Latency.FailingBrain(kind: .rulesOnly),
                ]
            )

            // The plain call is where the failure surfaces today: an error, and nothing shown.
            await #expect(throws: (any Error).self) {
                _ = try await router.answer(question: Latency.lookup, context: packet, category: .recall)
            }

            let caught = Latency.Caught()
            let final = try await router.answerProgressively(
                question: Latency.lookup, context: packet, category: .recall
            ) { caught.hold($0) }

            let floor = try #require(caught.value)
            // Not "an error", and not a placeholder: the exact grounded answer already on
            // screen. Taking a real answer back to show a failure is a downgrade.
            #expect(final.text == floor.text)
            #expect(final.brain == .rulesOnly)
            #expect(final.text.contains("Priya"))
            assertNoNetwork()
        }
    }

    @Test("CF-17c a failure with no floor to keep still surfaces as an error")
    func failureWithoutFloorStillThrows() async throws {
        try await TestWorkspace.with { ws in
            let store = try await ws.store()
            let (_, packet) = try await Latency.world(store)

            let router = BrainFlow.router(
                preferred: .appleOnDevice,
                store: store,
                brains: [
                    .appleOnDevice: Latency.FailingBrain(kind: .appleOnDevice),
                    .rulesOnly: Latency.FailingBrain(kind: .rulesOnly),
                ]
            )

            // A general question the floor declines to answer specifically. With nothing to
            // keep, the failure must not be swallowed into a comfortable silence.
            await #expect(throws: (any Error).self) {
                _ = try await router.answerProgressively(
                    question: "what was I doing in 1995", context: packet, category: .recall
                ) { _ in
                    Issue.record("the floor answered a question it has no record of")
                }
            }
            assertNoNetwork()
        }
    }
}
