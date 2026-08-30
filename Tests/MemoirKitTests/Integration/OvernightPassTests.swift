//
//  OvernightPassTests.swift
//
//  The deep pass: reading a whole day instead of the last three rows of it, and
//  saying out loud that it happened.
//
//  Two failures are being guarded against, and they are the same failure twice.
//
//  - The extractor used to take `captures.suffix(8)` and ask once. A reindex over
//    twenty thousand rows showed the model three of them and reported success. The
//    sweep tests below assert that a batch shape asks about every window, and that
//    the live shape still asks exactly once so consolidation stays affordable.
//  - A model pass that fails and a model pass that finds nothing both write no rows.
//    `ExtractionTelemetry` and `PassRecord` exist to separate them, so the tests here
//    assert that a run which reached nothing is distinguishable from a quiet one.
//

import Foundation
import Testing

import MemoirFixtures
@testable import MemoirKit

@Suite("Overnight pass")
struct OvernightPassTests {

    /// Captures spaced a minute apart, each with enough text to be worth a line.
    private func captures(_ n: Int) -> [CaptureEvent] {
        (0..<n).map { i in
            Fixtures.capture(
                text: "Working on the invoice for Acme, item \(i), and the notes beside it.",
                app: "Notes",
                bundleID: "com.apple.Notes",
                windowTitle: "Invoice",
                at: TestClock.reference.addingTimeInterval(Double(i) * 60),
                name: "sweep-\(i)"
            )
        }
    }

    // MARK: - Windowing

    @Test("a batch cuts into windows of at most the capture ceiling")
    func windowsRespectCaptureCeiling() {
        let extractor = LLMExtractor(
            brain: StubBrain(), useGuidedGeneration: false,
            maxCapturesPerCall: 5, maxCharsPerCall: 100_000, maxCalls: 100)
        let windows = extractor.buildWindows(captures(12))

        #expect(windows.count == 3)
        #expect(windows.allSatisfy { $0.lines.count <= 5 })
        #expect(windows.map(\.lines.count).reduce(0, +) == 12)
    }

    @Test("every window numbers its own lines from zero")
    func windowsRenumber() {
        let extractor = LLMExtractor(
            brain: StubBrain(), useGuidedGeneration: false,
            maxCapturesPerCall: 4, maxCharsPerCall: 100_000, maxCalls: 100)
        let windows = extractor.buildWindows(captures(9))

        // A model told to return "the bracketed index of that line" can only mean the lines it
        // was shown. A global counter would put [8] in front of a model handed four lines.
        for window in windows {
            #expect(window.lines.first?.hasPrefix("[0] ") == true)
            #expect(window.index.keys.sorted() == Array(0..<window.lines.count))
        }
    }

    @Test("a window's index points back at the capture that produced each line")
    func windowIndexResolves() {
        let batch = captures(6)
        let extractor = LLMExtractor(
            brain: StubBrain(), useGuidedGeneration: false,
            maxCapturesPerCall: 3, maxCharsPerCall: 100_000, maxCalls: 100)
        let windows = extractor.buildWindows(batch)

        #expect(windows.count == 2)
        // Second window holds the later half, still numbered from zero.
        #expect(windows[1].index[0]?.id == batch[3].id)
        #expect(windows[1].index[2]?.id == batch[5].id)
    }

    @Test("captures with no text never open a window")
    func emptyCapturesSkipped() {
        let blank = Fixtures.capture(
            text: "   ", app: "Finder", bundleID: "com.apple.finder",
            windowTitle: nil, at: TestClock.reference, name: "blank")
        let extractor = LLMExtractor(
            brain: StubBrain(), useGuidedGeneration: false,
            maxCapturesPerCall: 40, maxCharsPerCall: 100_000, maxCalls: 100)

        #expect(extractor.buildWindows([blank]).isEmpty)
        #expect(extractor.buildWindows(captures(2) + [blank]).first?.lines.count == 2)
    }

    // MARK: - Live shape versus batch shape

    @Test("the live shape asks once, about the newest window")
    func liveShapeAsksOnce() async throws {
        let brain = StubBrain(completionText: "[]")
        // maxCalls defaults to 1: this is exactly what consolidation runs during a session.
        let extractor = LLMExtractor(
            brain: brain, useGuidedGeneration: false,
            maxCapturesPerCall: 4, maxCharsPerCall: 100_000)

        _ = try await extractor.extract(from: captures(20))

        #expect(brain.completeCallCount == 1)
        // The newest capture, not the oldest: the live pass reads what is on screen now.
        let prompt = try #require(brain.lastPrompt)
        #expect(prompt.contains("item 19"))
        #expect(!prompt.contains("item 0,"))
    }

    @Test("the batch shape asks about every window")
    func batchShapeSweeps() async throws {
        let brain = StubBrain(completionText: "[]")
        let extractor = LLMExtractor(
            brain: brain, useGuidedGeneration: false,
            maxCapturesPerCall: 4, maxCharsPerCall: 100_000, maxCalls: 100)

        _ = try await extractor.extract(from: captures(20))

        #expect(brain.completeCallCount == 5)
    }

    @Test("maxCalls is a ceiling, and it keeps the newest windows")
    func maxCallsStopsTheSweep() async throws {
        let brain = StubBrain(completionText: "[]")
        let extractor = LLMExtractor(
            brain: brain, useGuidedGeneration: false,
            maxCapturesPerCall: 4, maxCharsPerCall: 100_000, maxCalls: 2)

        _ = try await extractor.extract(from: captures(20))

        #expect(brain.completeCallCount == 2)
        // A night that runs out of time should have read the most recent day, not the oldest.
        #expect(brain.lastPrompt?.contains("item 19") == true)
    }

    @Test("a sweep keeps rows from every window it reached")
    func sweepMergesAcrossWindows() async throws {
        // One row per call, with a title that differs per window because the evidence differs.
        let brain = StubBrain(completionText: """
            [{"kind":"project","title":"Acme Invoice","confidence":0.7,"source":0,
              "evidence":"Working on the invoice for Acme"}]
            """)
        let extractor = LLMExtractor(
            brain: brain, useGuidedGeneration: false,
            maxCapturesPerCall: 4, maxCharsPerCall: 100_000, maxCalls: 100)

        let result = try await extractor.extract(from: captures(20))

        #expect(brain.completeCallCount == 5)
        // Same title five times merges to one entity carrying provenance from each window.
        #expect(result.entities.count == 1)
        #expect(result.provenance.count >= 1)
    }

    @Test("the batch constructor is sized for a model that is not Apple's 3B")
    func batchConstructorSizing() {
        let extractor = LLMExtractor.batch(brain: StubBrain(), maxCalls: 7)
        // Forty captures per window: the number that overflows the on-device model and is
        // unremarkable for a 30B. If this ever becomes the live default, the live path has
        // silently inherited the failure this file's history is about.
        #expect(extractor.buildWindows(captures(120)).count == 3)
    }

    // MARK: - The guided fallback must not inherit batch sizes

    @Test("the guided fallback re-cuts a batch window to a size the small model survives")
    func guidedFallbackIsResized() {
        let long = (0..<200).map { "[\($0)] a reasonably long line of captured screen text here" }
        let fitted = LLMExtractor.fitForGuided(long)

        #expect(fitted.count < long.count)
        #expect(fitted.joined().count < LLMExtractor.guidedSafeChars)
        // The tail survives, so the newest activity in the window is what the small model sees,
        // and bracket numbers are never rewritten so every source still resolves.
        #expect(fitted.last == long.last)
        #expect(fitted.first?.hasPrefix("[0] ") == false)
    }

    @Test("a window already small enough passes through the guided cut untouched")
    func guidedFallbackLeavesSmallWindows() {
        let small = ["[0] short", "[1] also short"]
        #expect(LLMExtractor.fitForGuided(small) == small)
    }

    // MARK: - Telemetry: the two silences

    @Test("a model that answers is recorded as having answered")
    func telemetryCountsBrain() async throws {
        let telemetry = ExtractionTelemetry()
        let extractor = LLMExtractor(
            brain: StubBrain(completionText: "[]"), useGuidedGeneration: false,
            maxCapturesPerCall: 4, maxCharsPerCall: 100_000, maxCalls: 100,
            telemetry: telemetry)

        _ = try await extractor.extract(from: captures(12))

        let counts = await telemetry.counts
        #expect(counts.asked == 3)
        #expect(counts.brain == 3)
        #expect(counts.failed == 0)
        let reached = await telemetry.reachedModel
        #expect(reached)
    }

    @Test("a model that never answers is distinguishable from a quiet night")
    func telemetryCountsFailure() async throws {
        // Available, then throws: the shape a sleeping Mac mini actually has.
        let telemetry = ExtractionTelemetry()
        let extractor = LLMExtractor(
            brain: FailingBrain(), useGuidedGeneration: false,
            maxCapturesPerCall: 4, maxCharsPerCall: 100_000, maxCalls: 100,
            telemetry: telemetry)

        let result = try await extractor.extract(from: captures(12))

        // No rows, exactly like a night where nothing stood out, and yet plainly different.
        #expect(result.isEmpty)
        let counts = await telemetry.counts
        #expect(counts.asked == 3)
        #expect(counts.failed == 3)
        let reached = await telemetry.reachedModel
        #expect(reached == false)
    }

    // MARK: - The run record

    @Test("a run record round-trips and reports itself in one line")
    func passRecordRoundTrips() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("memoir-pass-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = PassRecordStore.url(alongsideDatabase: dir.appendingPathComponent("memoir.sqlite"))

        let record = PassRecord(
            startedAt: TestClock.reference,
            finishedAt: TestClock.reference.addingTimeInterval(600),
            since: TestClock.reference.addingTimeInterval(-86_400),
            brain: "localNetwork",
            capturesRead: 1_240,
            entitiesTouched: 31,
            reachedModel: true,
            windowsAsked: 40,
            windowsFailed: 2
        )
        try PassRecordStore.append(record, at: url)

        let loaded = try #require(PassRecordStore.latest(at: url))
        #expect(loaded == record)
        #expect(loaded.summary().contains("1240 capture(s) read"))
        #expect(loaded.summary().contains("38/40 window(s) answered"))
    }

    @Test("a fresh run that reached nothing does not hide the last one that did")
    func latestReachingModelIgnoresFailures() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("memoir-pass-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = PassRecordStore.url(alongsideDatabase: dir.appendingPathComponent("memoir.sqlite"))

        func run(at ts: Date, reached: Bool) -> PassRecord {
            PassRecord(
                startedAt: ts, finishedAt: ts, since: ts, brain: "localNetwork",
                capturesRead: 10, entitiesTouched: 0, reachedModel: reached,
                windowsAsked: 4, windowsFailed: reached ? 0 : 4)
        }
        try PassRecordStore.append(run(at: TestClock.reference, reached: true), at: url)
        try PassRecordStore.append(
            run(at: TestClock.reference.addingTimeInterval(86_400), reached: false), at: url)

        // The job is running nightly and reaching nothing. A check that only asked "when did it
        // last run" would call that healthy, which is the whole failure this record exists for.
        #expect(PassRecordStore.latest(at: url)?.reachedModel == false)
        #expect(PassRecordStore.latestReachingModel(at: url)?.finishedAt == TestClock.reference)
    }

    @Test("the history is capped so the record stays a thing you can read")
    func historyIsCapped() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("memoir-pass-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = PassRecordStore.url(alongsideDatabase: dir.appendingPathComponent("memoir.sqlite"))

        for i in 0..<(PassRecordStore.maxKept + 5) {
            try PassRecordStore.append(
                PassRecord(
                    startedAt: TestClock.reference.addingTimeInterval(Double(i)),
                    finishedAt: TestClock.reference.addingTimeInterval(Double(i)),
                    since: TestClock.reference, brain: "localNetwork",
                    capturesRead: i, entitiesTouched: 0, reachedModel: true),
                at: url)
        }

        let list = PassRecordStore.load(at: url)
        #expect(list.count == PassRecordStore.maxKept)
        // The oldest go, not the newest.
        #expect(list.last?.capturesRead == PassRecordStore.maxKept + 4)
    }
}
