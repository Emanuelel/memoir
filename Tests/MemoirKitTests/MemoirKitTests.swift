import Testing
import Foundation
@testable import MemoirKit

// MARK: - Helpers

/// A throwaway store in its own temp directory.
private func makeStore() throws -> (Store, URL) {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("memoir-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let store = try Store(path: dir.appendingPathComponent("t.sqlite"))
    return (store, dir)
}

private func cleanup(_ dir: URL) {
    try? FileManager.default.removeItem(at: dir)
}

private func capture(
    _ text: String,
    app: String = "Slack",
    bundle: String = "com.tinyspeck.slackmacgap",
    at ts: Date = Date()
) -> CaptureEvent {
    CaptureEvent(
        ts: ts,
        appBundleID: bundle,
        appName: app,
        windowTitle: "#engineering",
        text: text,
        textHash: UUID().uuidString
    )
}

// MARK: - Store

@Suite("Store")
struct StoreTests {

    @Test("captures round-trip and read back in range")
    func captureRoundTrip() async throws {
        let (store, dir) = try makeStore()
        defer { cleanup(dir) }

        let now = Date()
        let a = capture("hello world", at: now.addingTimeInterval(-60))
        try await store.insert(capture: a)

        let read = try await store.captures(since: now.addingTimeInterval(-3600), limit: 100)
        #expect(read.count == 1)
        #expect(read.first?.text == "hello world")

        let byID = try await store.capture(id: a.id)
        #expect(byID?.id == a.id)
        #expect(byID?.appName == "Slack")
    }

    @Test("entity upsert, fetch and soft delete")
    func entityLifecycle() async throws {
        let (store, dir) = try makeStore()
        defer { cleanup(dir) }

        var e = Entity(kind: .commitment, title: "Send the invoice")
        try await store.upsert(entity: e)

        var all = try await store.entities(kind: .commitment, includeDeleted: false)
        #expect(all.count == 1)

        e.confidence = 0.9
        try await store.upsert(entity: e)
        all = try await store.entities(kind: .commitment, includeDeleted: false)
        #expect(all.count == 1, "upsert must update, not duplicate")
        #expect(all.first?.confidence == 0.9)

        try await store.deleteEntity(id: e.id)
        let live = try await store.entities(kind: nil, includeDeleted: false)
        let withDeleted = try await store.entities(kind: nil, includeDeleted: true)
        #expect(live.isEmpty)
        #expect(withDeleted.count == 1)
    }

    @Test("provenance round-trips and links to its capture")
    func provenanceRoundTrip() async throws {
        let (store, dir) = try makeStore()
        defer { cleanup(dir) }

        let c = capture("I'll send the invoice tomorrow")
        try await store.insert(capture: c)
        let e = Entity(kind: .commitment, title: "Send the invoice")
        try await store.upsert(entity: e)
        try await store.add(provenance: Provenance(
            entityID: e.id, captureID: c.id, field: "title", snippet: "I'll send the invoice"
        ))

        let rows = try await store.provenance(entityID: e.id)
        #expect(rows.count == 1)
        #expect(rows.first?.captureID == c.id)
        #expect(rows.first?.snippet.contains("invoice") == true)
    }

    @Test("search finds captures and entities")
    func search() async throws {
        let (store, dir) = try makeStore()
        defer { cleanup(dir) }

        try await store.insert(capture: capture("the quarterly roadmap review is Thursday"))
        try await store.insert(capture: capture("lunch plans", app: "Messages"))
        try await store.upsert(entity: Entity(kind: .project, title: "Quarterly roadmap"))

        let hits = try await store.searchCaptures("roadmap", limit: 10)
        #expect(hits.count == 1)
        #expect(hits.first?.text.contains("roadmap") == true)

        let entities = try await store.searchEntities("roadmap", limit: 10)
        #expect(entities.count == 1)
    }

    @Test("retention deletes only what is older than the cutoff")
    func retention() async throws {
        let (store, dir) = try makeStore()
        defer { cleanup(dir) }

        let now = Date()
        try await store.insert(capture: capture("old", at: now.addingTimeInterval(-10 * 86_400)))
        try await store.insert(capture: capture("recent", at: now.addingTimeInterval(-3_600)))
        try await store.upsert(entity: Entity(kind: .note, title: "keep me"))

        let removed = try await store.purgeCaptures(olderThan: now.addingTimeInterval(-5 * 86_400))
        #expect(removed == 1)

        let left = try await store.captures(since: .distantPast, limit: 100)
        #expect(left.count == 1)
        #expect(left.first?.text == "recent")

        // Entities survive retention. That is the two-tier rule.
        let entities = try await store.entities(kind: nil, includeDeleted: false)
        #expect(entities.count == 1)
    }

    @Test("purgeEverything empties the database")
    func purgeEverything() async throws {
        let (store, dir) = try makeStore()
        defer { cleanup(dir) }

        try await store.insert(capture: capture("something"))
        try await store.upsert(entity: Entity(kind: .note, title: "something"))
        try await store.purgeEverything()

        let stats = try await store.stats()
        #expect(stats.captureCount == 0)
        #expect(stats.entityCount == 0)
    }

    @Test("stats report real counts")
    func stats() async throws {
        let (store, dir) = try makeStore()
        defer { cleanup(dir) }

        try await store.insert(capture: capture("one"))
        try await store.insert(capture: capture("two"))
        try await store.upsert(entity: Entity(kind: .person, title: "Sara"))

        let s = try await store.stats()
        #expect(s.captureCount == 2)
        #expect(s.entityCount == 1)
        #expect(s.fileSizeBytes > 0)
        #expect(s.oldestCapture != nil)
    }
}

// MARK: - Extraction

@Suite("RuleExtractor")
struct RuleExtractorTests {

    @Test("finds commitments in realistic chatter")
    func findsCommitments() async throws {
        let text = """
        Sara: can you review the PR before standup tomorrow?
        me: yes, I'll send the invoice to Acme by Friday
        """
        let result = try await RuleExtractor().extract(from: [capture(text)])
        let commitments = result.entities.filter { $0.kind == .commitment }
        #expect(!commitments.isEmpty, "should find at least one commitment")
    }

    @Test("every entity carries provenance")
    func alwaysHasProvenance() async throws {
        let text = "I'll ship the release notes tomorrow. Thanks Marco. Ticket ABC-123 is blocked."
        let result = try await RuleExtractor().extract(from: [capture(text)])

        #expect(!result.entities.isEmpty)
        for entity in result.entities {
            let rows = result.provenance.filter { $0.entityID == entity.id }
            #expect(!rows.isEmpty, "entity '\(entity.title)' has no provenance")
        }
    }

    @Test("produces nothing from empty input")
    func emptyInput() async throws {
        let result = try await RuleExtractor().extract(from: [])
        #expect(result.isEmpty)
    }
}

// MARK: - MemoryService

@Suite("MemoryService")
struct MemoryServiceTests {

    @Test("consolidate is idempotent")
    func idempotent() async throws {
        let (store, dir) = try makeStore()
        defer { cleanup(dir) }

        let service = MemoryService(store: store, extractors: [RuleExtractor()])
        try await store.insert(capture: capture("I'll send the invoice to Acme tomorrow"))

        _ = try await service.consolidate(since: .distantPast)
        let first = try await store.entities(kind: nil, includeDeleted: false).count

        _ = try await service.consolidate(since: .distantPast)
        let second = try await store.entities(kind: nil, includeDeleted: false).count

        #expect(first == second, "running twice must not duplicate entities")
    }

    @Test("a user-corrected entity is never overwritten")
    func correctionsArePermanent() async throws {
        let (store, dir) = try makeStore()
        defer { cleanup(dir) }

        let service = MemoryService(store: store, extractors: [RuleExtractor()])
        try await store.insert(capture: capture("I'll send the invoice to Acme tomorrow"))
        _ = try await service.consolidate(since: .distantPast)

        let existing = try await store.entities(kind: nil, includeDeleted: false)
        guard var entity = existing.first else {
            Issue.record("extraction produced nothing to correct")
            return
        }

        entity.title = "MY CORRECTED TITLE"
        entity.detail = "user wrote this"
        entity.corrected = true
        try await store.upsert(entity: entity)

        // Re-observe the same evidence several times.
        for _ in 0..<3 {
            try await store.insert(capture: capture("I'll send the invoice to Acme tomorrow"))
            _ = try await service.consolidate(since: .distantPast)
        }

        let after = try await store.entity(id: entity.id)
        #expect(after?.title == "MY CORRECTED TITLE", "extraction overwrote a user correction")
        #expect(after?.detail == "user wrote this")
        #expect(after?.corrected == true)
    }

    @Test("a forgotten entity is not resurrected by re-observation")
    func deletionSticks() async throws {
        let (store, dir) = try makeStore()
        defer { cleanup(dir) }

        let service = MemoryService(store: store, extractors: [RuleExtractor()])
        try await store.insert(capture: capture("I'll send the invoice to Acme tomorrow"))
        _ = try await service.consolidate(since: .distantPast)

        let existing = try await store.entities(kind: nil, includeDeleted: false)
        guard let entity = existing.first else { return }
        try await store.deleteEntity(id: entity.id)

        try await store.insert(capture: capture("I'll send the invoice to Acme tomorrow"))
        _ = try await service.consolidate(since: .distantPast)

        let after = try await store.entity(id: entity.id)
        #expect(after?.deleted == true, "a forgotten entity came back")
    }

    @Test("context never exceeds its budget")
    func contextBudget() async throws {
        let (store, dir) = try makeStore()
        defer { cleanup(dir) }

        let service = MemoryService(store: store, extractors: [RuleExtractor()])
        for i in 0..<200 {
            try await store.insert(capture: capture(
                "line \(i) " + String(repeating: "filler text ", count: 40)
            ))
        }

        let budget = 500
        let packet = try await service.context(for: "what did I do", budget: budget)
        #expect(packet.summary.count <= budget * 4 + 64, "packet blew its budget")
    }

    @Test("context prioritises pinned entities")
    func contextPrioritisesPinned() async throws {
        let (store, dir) = try makeStore()
        defer { cleanup(dir) }

        let service = MemoryService(store: store, extractors: [RuleExtractor()])
        var pinned = Entity(kind: .project, title: "PINNED PROJECT")
        pinned.pinned = true
        try await store.upsert(entity: pinned)

        let packet = try await service.context(for: "anything", budget: 800)
        #expect(packet.summary.contains("PINNED PROJECT"))
        #expect(packet.entityIDs.contains(pinned.id))
    }

    @Test("retention through the service leaves entities alone")
    func serviceRetention() async throws {
        let (store, dir) = try makeStore()
        defer { cleanup(dir) }

        let service = MemoryService(store: store, extractors: [RuleExtractor()])
        try await store.insert(capture: capture("old", at: Date().addingTimeInterval(-40 * 86_400)))
        try await store.upsert(entity: Entity(kind: .note, title: "durable"))

        let removed = try await service.applyRetention(captureDays: 30)
        #expect(removed == 1)
        let left = try await store.entities(kind: nil, includeDeleted: false)
        #expect(left.count == 1)
    }
}

// MARK: - Restraint

@Suite("RestraintEngine")
struct RestraintTests {

    private func at(_ hour: Int, _ minute: Int = 0) -> Date {
        var c = DateComponents()
        c.year = 2026; c.month = 7; c.day = 15; c.hour = hour; c.minute = minute
        return Calendar.current.date(from: c)!
    }

    @Test("stays silent inside quiet hours that wrap midnight")
    func quietHoursWrapping() async throws {
        var config = RestraintConfig.default
        config.quietHours = QuietHours(start: 22, end: 7, enabled: true)
        let engine = RestraintEngine(config: config)

        let late = await engine.propose(.idleReturn, now: at(23))
        let early = await engine.propose(.idleReturn, now: at(3))
        #expect(late == nil, "23:00 is inside 22 to 7")
        #expect(early == nil, "03:00 is inside 22 to 7")
    }

    @Test("speaks outside quiet hours")
    func speaksWhenAllowed() async throws {
        var config = RestraintConfig.default
        config.quietHours = QuietHours(start: 22, end: 7, enabled: true)
        let engine = RestraintEngine(config: config)
        let midday = await engine.propose(.idleReturn, now: at(14))
        #expect(midday != nil)
    }

    @Test("cooldown suppresses a second nudge")
    func cooldown() async throws {
        var config = RestraintConfig.default
        config.quietHours = QuietHours(start: 0, end: 0, enabled: false)
        config.cooldownSeconds = 900
        let engine = RestraintEngine(config: config)

        let first = await engine.propose(.idleReturn, now: at(10, 0))
        let tooSoon = await engine.propose(.dailySummaryReady, now: at(10, 5))
        let later = await engine.propose(.dailySummaryReady, now: at(10, 30))
        #expect(first != nil)
        #expect(tooSoon == nil, "inside cooldown")
        #expect(later != nil, "past cooldown")
    }

    @Test("focus mode silences everything")
    func focusMode() async throws {
        var config = RestraintConfig.default
        config.quietHours = QuietHours(start: 0, end: 0, enabled: false)
        config.suppressDuringFocus = true
        let engine = RestraintEngine(config: config)

        await engine.setFocusMode(true)
        let silenced = await engine.propose(.idleReturn, now: at(11))
        #expect(silenced == nil)

        await engine.setFocusMode(false)
        let allowed = await engine.propose(.idleReturn, now: at(11))
        #expect(allowed != nil)
    }

    @Test("daily cap is enforced")
    func dailyCap() async throws {
        var config = RestraintConfig.default
        config.quietHours = QuietHours(start: 0, end: 0, enabled: false)
        config.cooldownSeconds = 0
        config.maxNudgesPerDay = 2
        let engine = RestraintEngine(config: config)

        let a = await engine.propose(.idleReturn, now: at(9))
        let b = await engine.propose(.idleReturn, now: at(10))
        let c = await engine.propose(.idleReturn, now: at(11))
        #expect(a != nil)
        #expect(b != nil)
        #expect(c == nil, "over the daily cap")
    }
}

// MARK: - Brain routing

@Suite("BrainRouter")
struct BrainRouterTests {

    @Test("a cloud brain is never chosen while allowCloud is off")
    func cloudNeverLeaks() async throws {
        let (store, dir) = try makeStore()
        defer { cleanup(dir) }

        var config = BrainConfig()
        config.allowCloud = false
        config.anthropicAPIKey = "sk-ant-not-a-real-key"

        // Explicitly *prefer* the cloud, and it still must not be selected.
        let router = BrainRouter(preferred: .anthropicAPI, store: store, config: config)
        let available = await router.available()
        #expect(!available.contains(.anthropicAPI), "cloud brain offered while allowCloud is false")
        #expect(!available.contains(.claudeCode), "cloud brain offered while allowCloud is false")

        let chosen = await router.current()
        #expect(chosen.isCloud == false, "router selected a cloud brain with allowCloud false")
    }

    @Test("rulesOnly is always available and always answers")
    func rulesOnlyFloor() async throws {
        let (store, dir) = try makeStore()
        defer { cleanup(dir) }

        try await store.upsert(entity: Entity(kind: .commitment, title: "Send the invoice"))

        let brain = RulesOnlyBrain(store: store)
        let available = await brain.isAvailable()
        #expect(available)

        let answer = try await brain.answer(
            question: "what do I owe anyone",
            context: ContextPacket(summary: "Open commitments:\n- Send the invoice")
        )
        #expect(!answer.text.isEmpty)
        #expect(answer.brain == .rulesOnly)
    }

    @Test("falls back to a local brain rather than failing")
    func fallback() async throws {
        let (store, dir) = try makeStore()
        defer { cleanup(dir) }

        var config = BrainConfig()
        config.allowCloud = false
        let router = BrainRouter(preferred: .anthropicAPI, store: store, config: config)

        let answer = try await router.answer(
            question: "anything",
            context: ContextPacket(summary: "")
        )
        #expect(answer.brain.isCloud == false)
        #expect(!answer.text.isEmpty)
    }
}

// MARK: - Config

@Suite("Config safety")
struct ConfigTests {

    @Test("the API key is never encoded into the config file")
    func keyNeverSerialised() throws {
        var config = BrainConfig()
        config.anthropicAPIKey = "sk-ant-SECRETVALUE"
        let data = try JSONEncoder().encode(config)
        let json = String(decoding: data, as: UTF8.self)
        #expect(!json.contains("SECRETVALUE"), "API key was written into serialised config")
        #expect(!json.contains("anthropicAPIKey"))
    }

    @Test("cloud is off by default")
    func cloudOffByDefault() {
        #expect(BrainConfig().allowCloud == false)
    }

    @Test("password managers are excluded out of the box")
    func defaultExclusions() {
        let excluded = CaptureConfig().excludedBundleIDs
        #expect(!excluded.isEmpty, "there should be sensible default exclusions")
    }
}
