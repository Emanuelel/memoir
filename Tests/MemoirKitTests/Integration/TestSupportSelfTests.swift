//
//  TestSupportSelfTests.swift
//  The harness testing itself.
//
//  These are not CF flows; they are the load-bearing checks under every CF flow, so they
//  carry a TS-* prefix instead of a CF-* one. If one of these goes red, no CF result below
//  it can be trusted: the isolation, the clock or the network blocker is broken.
//

import Foundation
import Testing

import MemoirFixtures
@testable import MemoirKit

@Suite("TestSupport")
struct TestSupportSelfTests {

    // MARK: - TS-1 isolation

    @Test("TS-1 two workspaces are isolated and neither is the user's real Memoir folder")
    func workspacesAreIsolated() async throws {
        try await TestWorkspace.with { a in
            try await TestWorkspace.with { b in
                #expect(a.root != b.root)
                #expect(a.dbURL != b.dbURL)

                // Both live under the system temp directory, never under
                // ~/Library/Application Support/Memoir.
                let temp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                    .resolvingSymlinksInPath().path
                for workspace in [a, b] {
                    #expect(workspace.root.resolvingSymlinksInPath().path.hasPrefix(temp))
                    #expect(!workspace.root.path.contains("Application Support"))
                }

                // Two real stores on two real files do not see each other.
                let storeA = try await a.store()
                let storeB = try await b.store()
                try await storeA.insert(capture: Fixtures.email(at: TestClock.reference))

                let inA = try await storeA.captures(since: TestClock.days(-1), limit: 10)
                let inB = try await storeB.captures(since: TestClock.days(-1), limit: 10)
                #expect(inA.count == 1)
                #expect(inB.isEmpty)

                await storeA.close()
                await storeB.close()
            }
        }
    }

    @Test("TS-1 the workspace directory is removed even when the body throws")
    func cleanupSurvivesAThrow() async throws {
        struct Boom: Error {}
        var captured: URL?

        await #expect(throws: Boom.self) {
            try await TestWorkspace.with { workspace in
                captured = workspace.root
                let store = try await workspace.store()
                try await store.insert(capture: Fixtures.slackThread())
                await store.close()
                #expect(FileManager.default.fileExists(atPath: workspace.dbURL.path))
                throw Boom()
            }
        }

        let root = try #require(captured)
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    // MARK: - TS-2 path redirection

    @Test("TS-2 inside with(), every Memoir path resolves into the workspace")
    func pathsAreRedirected() async throws {
        // The real folder, computed without calling Paths.supportDirectory(): that call
        // creates the directory as a side effect, and this suite must never touch it.
        let realSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Memoir", isDirectory: true)

        // Outside the binding there is no override, so production behaviour is untouched.
        #expect(Paths.supportDirectoryOverride == nil)

        try await TestWorkspace.with { workspace in
            #expect(Paths.supportDirectory() == workspace.root)
            #expect(Paths.databaseURL() == workspace.dbURL)
            #expect(Paths.configURL() == workspace.configURL)
            #expect(Paths.logsDirectory().appendingPathComponent("memoir.log") == workspace.logURL)
            #expect(Store.defaultPath() == workspace.dbURL)
            #expect(Paths.supportDirectory() != realSupport)

            // Opening a store logs, and the log must land in the workspace, not in
            // ~/Library/Application Support/Memoir/logs.
            let store = try await workspace.store()
            await store.close()
            #expect(workspace.logContents().contains(workspace.dbURL.path))
        }

        #expect(Paths.supportDirectoryOverride == nil)
    }

    @Test("TS-2 config.json written through the workspace never carries the API key")
    func configNeverCarriesTheKey() async throws {
        try await TestWorkspace.with { workspace in
            let config = BrainConfig(
                anthropicAPIKey: TestSecrets.apiKey,
                claudeCodePath: "/usr/local/bin/claude",
                allowCloud: true
            )
            try workspace.writeConfig(config)

            let written = workspace.configContents()
            #expect(!written.isEmpty)
            #expect(written.contains("allowCloud"))
            #expect(!written.contains(TestSecrets.apiKeyNeedle))
            #expect(!workspace.anyArtifactContains(TestSecrets.apiKeyNeedle))
        }
    }

    // MARK: - TS-3 the network blocker

    @Test("TS-3 BlockingURLProtocol intercepts URLSession.shared and configuration-built sessions")
    func networkIsBlocked() async throws {
        BlockingURLProtocol.install()

        let shared = URL(string: "https://\(BlockingURLProtocol.probeHost)/shared")!
        let ephemeral = URL(string: "https://\(BlockingURLProtocol.probeHost)/ephemeral")!

        // 1. URLSession.shared, covered by URLProtocol.registerClass.
        await #expect(throws: (any Error).self) {
            _ = try await URLSession.shared.data(from: shared)
        }

        // 2. A session built from a configuration, covered only by the swizzle. This is the
        //    shape AnthropicBrain uses, and registerClass alone does *not* catch it.
        let session = URLSession(configuration: .ephemeral)
        await #expect(throws: (any Error).self) {
            _ = try await session.data(from: ephemeral)
        }
        session.invalidateAndCancel()

        let recorded = BlockingURLProtocol.attemptedRequests
        #expect(recorded.contains(shared), "URLSession.shared request was not intercepted")
        #expect(recorded.contains(ephemeral), "configuration-built session was not intercepted")

        // The probe host is excluded from the CF-2 assertion, so it cannot fail a
        // concurrently running flow test.
        #expect(BlockingURLProtocol.unexpectedRequests.allSatisfy { $0.host != BlockingURLProtocol.probeHost })
        assertNoNetwork()
    }

    @Test("TS-3 the swizzle actually reaches URLSessionConfiguration")
    func configurationCarriesTheBlocker() {
        BlockingURLProtocol.install()
        for config in [URLSessionConfiguration.default, URLSessionConfiguration.ephemeral] {
            let classes = config.protocolClasses ?? []
            #expect(classes.contains { $0 == BlockingURLProtocol.self })
        }
    }

    // MARK: - TS-4 the clock

    @Test("TS-4 the reference date is Monday 16 March 2026, 10:00 UTC")
    func referenceDateIsPinned() {
        #expect(TestClock.iso(TestClock.reference) == "2026-03-16T10:00:00Z")

        let c = TestClock.utcCalendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second, .weekday],
            from: TestClock.reference
        )
        #expect(c.year == 2026)
        #expect(c.month == 3)
        #expect(c.day == 16)
        #expect(c.hour == 10)
        #expect(c.minute == 0)
        #expect(c.second == 0)
        #expect(c.weekday == 2, "weekday 2 is Monday; weekday-relative fixtures depend on it")

        #expect(TestClock.utc(2026, 3, 16, 10, 0) == TestClock.reference)
    }

    @Test("TS-4 offsets are exact and compose")
    func offsetsAreExact() {
        #expect(TestClock.days(1).timeIntervalSince(TestClock.reference) == 86_400)
        #expect(TestClock.days(-120).timeIntervalSince(TestClock.reference) == -120 * 86_400)
        #expect(TestClock.hours(3).timeIntervalSince(TestClock.reference) == 10_800)
        #expect(TestClock.minutes(-30).timeIntervalSince(TestClock.reference) == -1_800)
        #expect(TestClock.seconds(45).timeIntervalSince(TestClock.reference) == 45)
        #expect(TestClock.hours(24, from: TestClock.days(-1)) == TestClock.reference)
        #expect(TestClock.sameLocalDay(TestClock.reference, TestClock.minutes(1)))
    }

    // MARK: - TS-5 fixtures

    @Test("TS-5 fixtures are stable, correctly hashed, and round-trip through a real Store")
    func fixturesRoundTrip() async throws {
        // Stability: building the same fixture twice produces the same row.
        #expect(Fixtures.slackThread() == Fixtures.slackThread())
        #expect(Fixtures.slackThread().id != Fixtures.email().id)
        #expect(Fixtures.slackThread(at: TestClock.reference).id != Fixtures.slackThread(at: TestClock.days(1)).id)

        try await TestWorkspace.with { workspace in
            let store = try await workspace.store()
            let captures = Fixtures.all()
            try await seed(store: store, captures: captures)

            for original in captures {
                let stored = try #require(try await store.capture(id: original.id))
                #expect(stored == original)
                #expect(stored.textHash == AccessibilityCapture.textHash(stored.text))
            }

            let listed = try await store.captures(since: TestClock.days(-1), limit: 100)
            #expect(listed.count == captures.count)
            await store.close()
        }
    }

    @Test("TS-5 the fixtures carry the material each flow needs")
    func fixturesCarryTheirContract() async throws {
        let extractor = RuleExtractor()

        // Slack: two commitments with two different date forms.
        //
        // It used to assert a decision and a thread here too. Extraction no longer produces
        // either — see `ExtractionBuilder.retiredKinds` — and the fixture text is unchanged,
        // so this now asserts the retirement instead. The patterns still fire; the builder
        // refuses the row.
        let slack = try await extractor.extract(from: [Fixtures.slackThread()])
        let dated = slack.entities.filter { $0.kind == .commitment && $0.dueAt != nil }
        #expect(dated.count >= 2)
        #expect(!slack.entities.contains { ExtractionBuilder.retiredKinds.contains($0.kind) },
                "a retired kind was produced: \(slack.entities.map { "\($0.kind):\($0.title)" })")

        // "by Friday" resolves to the coming Friday, "tomorrow" to the next day (both
        // against the capture timestamp, never the wall clock).
        let friday = TestClock.localCalendar.startOfDay(for: TestClock.days(4))
        let tomorrow = TestClock.localCalendar.startOfDay(for: TestClock.days(1))
        let dueDays = Set(dated.compactMap { $0.dueAt.map { TestClock.localCalendar.startOfDay(for: $0) } })
        #expect(dueDays.contains(friday), "expected a commitment due Friday 20 March")
        #expect(dueDays.contains(tomorrow), "expected a commitment due Tuesday 17 March")

        // Email: headers still become people. The subject line no longer becomes anything,
        // which is the point: a subject line extracted as a thread once billed an hour of
        // work as "**lunch thursday, works for me**, 24m".
        let email = try await extractor.extract(from: [Fixtures.email()])
        let people = Set(email.entities.filter { $0.kind == .person }.map(\.title))
        #expect(people.contains("Elena Rossi"))
        #expect(people.contains("Marco Bianchi"))
        #expect(!email.entities.contains { $0.kind == .thread },
                "the subject line became a thread again")

        // Standup: the ticket key is picked up as a project.
        let standup = try await extractor.extract(from: [Fixtures.standupNotes()])
        #expect(standup.entities.contains { $0.kind == .project && $0.title == "ACME-412" })

        // Terminal: pure noise. Nothing may be invented from build output.
        let terminal = try await extractor.extract(from: [Fixtures.terminalSession()])
        #expect(terminal.entities.isEmpty, "terminal noise produced \(terminal.entities.map(\.title))")

        // Code review: the repo slug becomes a project. The agreement no longer becomes a
        // decision — a 140-character sentence with no subject and no link to what was decided
        // about was read by exactly one keyword branch and rendered nowhere.
        let review = try await extractor.extract(from: [Fixtures.codeReview()])
        #expect(review.entities.contains { $0.kind == .project && $0.title == "acme-corp/platform" })
        #expect(!review.entities.contains { $0.kind == .decision })

        assertNoNetwork()
    }

    @Test("TS-5 volume builders are deterministic and correctly spaced")
    func volumeBuildersAreDeterministic() async throws {
        let a = makeCaptures(count: 240, spanningDays: 120, from: TestClock.days(-120))
        let b = makeCaptures(count: 240, spanningDays: 120, from: TestClock.days(-120))
        #expect(a == b)
        #expect(a.count == 240)
        #expect(Set(a.map(\.id)).count == 240)
        #expect(Set(a.map(\.textHash)).count == 240, "filler captures must not dedupe against each other")
        #expect(a.first?.ts == TestClock.days(-120))
        #expect(a.last?.ts == TestClock.days(-0.5))
        #expect(a.map(\.ts) == a.map(\.ts).sorted())

        let entities = makeEntities(count: 500, pinnedEvery: 50)
        #expect(entities.count == 500)
        #expect(Set(entities.map(\.id)).count == 500)
        #expect(entities.filter(\.pinned).count == 10)
        #expect(entities.filter { $0.kind == .commitment && $0.dueAt != nil }.count > 0)
        #expect(makeEntities(count: 500, pinnedEvery: 50) == entities)

        // They actually land in a real database.
        try await TestWorkspace.with { workspace in
            let store = try await workspace.store()
            try await seed(store: store, captures: Array(a.prefix(50)), entities: Array(entities.prefix(50)))
            let stats = try await store.stats()
            #expect(stats.captureCount == 50)
            #expect(stats.entityCount == 50)
            await store.close()
        }
    }

    @Test("TS-5 clock-free row builders round-trip through a real Store")
    func rowBuildersRoundTrip() async throws {
        try await TestWorkspace.with { workspace in
            let store = try await workspace.store()
            let capture = Fixtures.standupNotes()

            let entity = makeEntity(
                kind: .commitment,
                title: "Hand over the migration script",
                detail: "from standup",
                dueAt: TestClock.days(3),
                confidence: 0.7,
                at: TestClock.reference
            )
            let row = makeProvenance(
                entityID: entity.id,
                captureID: capture.id,
                snippet: "Finishing the migration script, will hand it over by Thursday.",
                at: TestClock.reference
            )
            let session = makeSession(
                appName: "Notes",
                bundleID: "com.apple.Notes",
                from: TestClock.reference,
                to: TestClock.minutes(25)
            )

            try await seed(
                store: store,
                captures: [capture],
                entities: [entity],
                provenance: [row],
                sessions: [session]
            )

            let storedEntity = try #require(try await store.entity(id: entity.id))
            #expect(storedEntity.createdAt == TestClock.reference)
            #expect(storedEntity.updatedAt == TestClock.reference)
            #expect(storedEntity.dueAt == TestClock.days(3))

            let storedProvenance = try await store.provenance(entityID: entity.id)
            #expect(storedProvenance.count == 1)
            #expect(storedProvenance.first?.captureID == capture.id)
            #expect(storedProvenance.first?.ts == TestClock.reference)

            let storedSessions = try await store.sessions(from: TestClock.days(-1), to: TestClock.days(1))
            #expect(storedSessions.count == 1)
            let duration: TimeInterval = try #require(storedSessions.first?.duration)
            #expect(duration == 1_500.0)

            // Deterministic: the same logical row built twice is the same row.
            #expect(makeEntity(kind: .commitment, title: "Hand over the migration script").id == entity.id)
            #expect(makeSession(
                appName: "Notes",
                bundleID: "com.apple.Notes",
                from: TestClock.reference,
                to: TestClock.minutes(25)
            ).id == session.id)

            await store.close()
        }
    }

    @Test("TS-5 the prepared brain configs say what they claim")
    func brainConfigsAreAsDocumented() {
        #expect(TestBrainConfig.localOnly.allowCloud == false)
        #expect(TestBrainConfig.localOnly.anthropicAPIKey == nil)
        #expect(TestBrainConfig.keyedButLocalOnly.allowCloud == false)
        #expect(TestBrainConfig.keyedButLocalOnly.anthropicAPIKey == TestSecrets.apiKey)
        #expect(TestBrainConfig.cloudEnabled().allowCloud)
        #expect(TestSecrets.apiKey.contains(TestSecrets.apiKeyNeedle))
        // Both cloud kinds must agree with the router's notion of "cloud".
        #expect(BrainKind.anthropicAPI.isCloud)
        #expect(BrainKind.claudeCode.isCloud)
        #expect(!BrainKind.appleOnDevice.isCloud)
        #expect(!BrainKind.rulesOnly.isCloud)
    }

    @Test("TS-5 the compiled memoir-mcp binary is where the MCP flows expect it")
    func mcpBinaryIsLocatable() throws {
        let url = try MCPBinary.url()
        #expect(FileManager.default.isExecutableFile(atPath: url.path))
        #expect(url.lastPathComponent == MCPBinary.name)
        #expect(MCPBinary.arguments(database: URL(fileURLWithPath: "/tmp/x.sqlite")) == ["--db", "/tmp/x.sqlite"])
    }

    // MARK: - TS-6 fake brains

    @Test("TS-6 StubBrain answers, counts, and can be flipped unavailable")
    func stubBrainBehaves() async throws {
        let brain = StubBrain(kind: .appleOnDevice, answerText: "Two things are open.")
        #expect(await brain.isAvailable())

        let packet = ContextPacket(summary: "s", captureIDs: ["c-1"], entityIDs: ["e-1"], approxTokens: 1)
        let answer = try await brain.answer(question: "what do I owe anyone", context: packet)
        #expect(answer.text == "Two things are open.")
        #expect(answer.brain == .appleOnDevice)
        #expect(answer.citedCaptureIDs == ["c-1"])
        #expect(brain.answerCallCount == 1)
        #expect(brain.lastQuestion == "what do I owe anyone")

        #expect(try await brain.complete(prompt: "p", maxTokens: 10) == "[]")
        #expect(brain.completeCallCount == 1)
        #expect(brain.availabilityCallCount == 1)

        brain.setAvailable(false)
        #expect(await brain.isAvailable() == false)

        brain.resetCounts()
        #expect(brain.answerCallCount == 0)
    }

    @Test("TS-6 FailingBrain reports available and then throws")
    func failingBrainBehaves() async throws {
        let brain = FailingBrain(kind: .anthropicAPI)
        #expect(await brain.isAvailable())

        await #expect(throws: MemoirError.self) {
            _ = try await brain.answer(question: "q", context: .empty)
        }
        await #expect(throws: MemoirError.self) {
            _ = try await brain.complete(prompt: "p", maxTokens: 10)
        }
        #expect(brain.callCount == 2)
    }

    @Test("TS-6 a stub brain drives LLMExtractor without a model or a network call")
    func stubBrainDrivesLLMExtractor() async throws {
        let brain = StubBrain(
            kind: .appleOnDevice,
            completionText: """
            [{"kind":"commitment","title":"Ship the rate limiter fix","detail":null,\
            "due":null,"confidence":0.8,"source":0,"evidence":"I'll have the fix merged"}]
            """
        )
        // The point of TS-6 is that a stub brain drives the extractor with no model and no
        // network. Guided generation would reach the real on-device model and prove the
        // opposite of what this asserts.
        let result = try await LLMExtractor(brain: brain, useGuidedGeneration: false)
            .extract(from: [Fixtures.slackThread()])
        #expect(result.entities.contains { $0.title == "Ship the rate limiter fix" })
        #expect(brain.completeCallCount == 1)
        #expect(!result.provenance.isEmpty, "every extracted entity must be traceable")
        assertNoNetwork()
    }
}
